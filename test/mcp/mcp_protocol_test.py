"""Independent MCP wire/schema and official-SDK checks against the real launcher."""

import asyncio
import copy
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time
import unittest

from jsonschema import Draft202012Validator, ValidationError
from mcp import Client, MCPError, StdioServerParameters
from referencing import Registry
from referencing.exceptions import NoSuchResource


HERE = Path(__file__).resolve().parent
APP_ROOT = Path(os.environ.get("OPSD_MCP_TEST_APP_ROOT", HERE.parents[1])).resolve()
TIMEOUT = 5
DISCOVER = json.loads((HERE / "fixtures/discover-request.json").read_text())
SCHEMA_BYTES = (HERE / "schema/schema.json").read_bytes()
SCHEMA = json.loads(SCHEMA_BYTES)
PROVENANCE = json.loads((HERE / "schema/provenance.json").read_text())


def reject_external_reference(uri):
    raise NoSuchResource(ref=uri)


def validate(definition, message):
    """Resolve only local definitions in the unmodified upstream schema."""
    validator = Draft202012Validator({
        "$schema": SCHEMA["$schema"],
        "$defs": SCHEMA["$defs"],
        "$ref": f"#/$defs/{definition}",
    }, registry=Registry(retrieve=reject_external_reference))
    validator.validate(message)


def request(method="server/discover", request_id=1, **params):
    message = copy.deepcopy(DISCOVER)
    message.update(method=method, id=request_id)
    message["params"].update(params)
    return message


def server_environment(workspace):
    # The protocol tests need no provider credentials or personal OPSd profile.
    env = {key: os.environ[key] for key in ("PATH", "HOME", "RUBY_BIN") if key in os.environ}
    env.update(OPSD_APP_ROOT=str(APP_ROOT), OPSD_WORKSPACE_ROOT=str(workspace))
    return env


class WireServer:
    """A bounded byte reader, independent of the Ruby test framing helpers."""

    def __enter__(self):
        self.workspace = tempfile.TemporaryDirectory(prefix="opsd-mcp-wire-")
        self.stderr = tempfile.TemporaryFile()
        self.process = subprocess.Popen(
            [str(APP_ROOT / "bin/opsd-mcp")],
            cwd=self.workspace.name,
            env=server_environment(self.workspace.name),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr,
        )
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""
        return self

    def diagnostics(self):
        self.stderr.seek(0)
        return self.stderr.read().decode("utf-8", errors="replace")

    def send(self, message):
        self.send_bytes((json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8"))

    def send_bytes(self, data):
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def receive(self):
        deadline = time.monotonic() + TIMEOUT
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise AssertionError(f"Timed out reading MCP response. stderr: {self.diagnostics()}")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise AssertionError(f"EOF before a complete MCP response. stderr: {self.diagnostics()}")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line.decode("utf-8"))

    def exchange(self, message, response_type, request_type=None):
        if request_type:
            validate(request_type, message)
        self.send(message)
        response = self.receive()
        validate(response_type, response)
        if "id" in message:
            assert response.get("id") == message["id"], response
        return response

    def __exit__(self, exc_type, exc_value, traceback):
        try:
            self.process.stdin.close()
            try:
                code = self.process.wait(timeout=TIMEOUT)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=1)
                raise AssertionError("MCP server did not exit after stdin closed")
            if exc_type is None:
                assert code == 0, self.diagnostics()
                assert self.buffer + self.process.stdout.read() == b"", "Unexpected stdout outside protocol responses"
                assert self.diagnostics() == "", self.diagnostics()
        finally:
            self.process.stdout.close()
            self.selector.close()
            self.stderr.close()
            self.workspace.cleanup()


class SchemaAndWireTest(unittest.TestCase):
    def test_upstream_schema_pin_and_offline_references(self):
        self.assertEqual(hashlib.sha256(SCHEMA_BYTES).hexdigest(), PROVENANCE["sha256"])
        self.assertEqual("2026-07-28", PROVENANCE["protocol"])
        self.assertIn(PROVENANCE["upstream_commit"], PROVENANCE["source"])
        Draft202012Validator.check_schema(SCHEMA)

        def check_refs(node):
            if isinstance(node, dict):
                if "$ref" in node:
                    self.assertTrue(node["$ref"].startswith("#/$defs/"), node["$ref"])
                for child in node.values():
                    check_refs(child)
            elif isinstance(node, list):
                for child in node:
                    check_refs(child)
        check_refs(SCHEMA)

    def test_live_requests_and_responses_match_official_schema(self):
        operations = [
            ("tools/list", "ListToolsRequest", "ListToolsResultResponse", {}),
            ("server/discover", "DiscoverRequest", "DiscoverResultResponse", {}),
            ("resources/list", "ListResourcesRequest", "ListResourcesResultResponse", {}),
            ("resources/templates/list", "ListResourceTemplatesRequest", "ListResourceTemplatesResultResponse", {}),
            ("prompts/list", "ListPromptsRequest", "ListPromptsResultResponse", {}),
            ("resources/read", "ReadResourceRequest", "ReadResourceResultResponse", {"uri": "opsd://contract"}),
            ("prompts/get", "GetPromptRequest", "GetPromptResultResponse",
             {"name": "verify-config", "arguments": {"manifest_path": "zażółć\nmanifest.yaml"}}),
            ("tools/call", "CallToolRequest", "CallToolResultResponse", {"name": "remove-resource", "arguments": {
                "resource": "database", "manifest_path": "demo.yaml", "resource_id": "db-main"}}),
        ]
        with WireServer() as server:
            # A catalog request deliberately precedes discovery: there is no handshake.
            for index, (method, req_type, resp_type, params) in enumerate(operations):
                with self.subTest(method=method):
                    response = server.exchange(request(method, index, **params), resp_type, req_type)
                    result = response["result"]
                    self.assertEqual("complete", result["resultType"])
                    self.assertEqual("opsd", result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"])
                    if "ttlMs" in result:
                        self.assertEqual(0, result["ttlMs"])
                        self.assertEqual("private", result["cacheScope"])
                    if method == "tools/call":
                        self.assertTrue(result["isError"])
                        self.assertEqual([], list(Path(server.workspace.name).iterdir()))

    def test_schema_rejects_missing_required_request_metadata(self):
        for key in ("io.modelcontextprotocol/protocolVersion", "io.modelcontextprotocol/clientCapabilities"):
            with self.subTest(key=key), WireServer() as server:
                message = request()
                del message["params"]["_meta"][key]
                with self.assertRaises(ValidationError):
                    validate("DiscoverRequest", message)
                response = server.exchange(message, "JSONRPCErrorResponse")
                self.assertEqual(-32602, response["error"]["code"])
                server.exchange(request(request_id=2), "DiscoverResultResponse", "DiscoverRequest")

    def test_schema_rejects_malformed_metadata_and_server_recovers(self):
        for invalid in (None, [], {"io.modelcontextprotocol/protocolVersion": 42}):
            with self.subTest(metadata=invalid), WireServer() as server:
                message = request()
                message["params"]["_meta"] = invalid
                with self.assertRaises(ValidationError):
                    validate("DiscoverRequest", message)
                response = server.exchange(message, "JSONRPCErrorResponse")
                self.assertEqual(-32602, response["error"]["code"])
                server.exchange(request(request_id=2), "DiscoverResultResponse", "DiscoverRequest")

    def test_unsupported_version_error_matches_official_schema(self):
        with WireServer() as server:
            for version in ("2025-11-25", "2099-01-01"):
                message = request()
                message["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] = version
                response = server.exchange(message, "UnsupportedProtocolVersionError", "DiscoverRequest")
                self.assertEqual(-32022, response["error"]["code"])
                self.assertEqual({"supported": ["2026-07-28"], "requested": version}, response["error"]["data"])
            server.exchange(request(request_id=2), "DiscoverResultResponse", "DiscoverRequest")

    def test_schema_rejects_corrupted_error_responses(self):
        with WireServer() as server:
            message = request()
            message["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] = "2025-11-25"
            valid = server.exchange(message, "UnsupportedProtocolVersionError", "DiscoverRequest")
        for field in ("supported", "requested"):
            with self.subTest(missing=field):
                corrupted = copy.deepcopy(valid)
                del corrupted["error"]["data"][field]
                with self.assertRaises(ValidationError):
                    validate("UnsupportedProtocolVersionError", corrupted)
        corrupted = copy.deepcopy(valid)
        corrupted["error"]["code"] = "-32022"
        with self.assertRaises(ValidationError):
            validate("JSONRPCErrorResponse", corrupted)

    def test_legacy_handshake_is_not_accepted(self):
        with WireServer() as server:
            message = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "legacy-test", "version": "1"},
            }}
            response = server.exchange(message, "JSONRPCErrorResponse")
            self.assertEqual(-32601, response["error"]["code"])
            self.assertIn("2026-07-28", response["error"]["message"])
            server.exchange(request(request_id=2), "DiscoverResultResponse", "DiscoverRequest")

    def test_invalid_json_and_envelopes_have_schema_valid_error_responses(self):
        with WireServer() as server:
            for data, expected_code in ((b"{broken\n", -32700), (b"\xff\n", -32700),
                                        (b"null\n", -32600), (b"[]\n", -32600)):
                server.send_bytes(data)
                response = server.receive()
                validate("JSONRPCErrorResponse", response)
                self.assertEqual(expected_code, response["error"]["code"])
            server.exchange(request(), "DiscoverResultResponse", "DiscoverRequest")

    def test_schema_rejects_corrupted_server_results(self):
        with WireServer() as server:
            valid = server.exchange(request(), "DiscoverResultResponse", "DiscoverRequest")
        for field in ("resultType", "ttlMs", "cacheScope", "supportedVersions", "capabilities"):
            with self.subTest(missing=field):
                corrupted = copy.deepcopy(valid)
                del corrupted["result"][field]
                with self.assertRaises(ValidationError):
                    validate("DiscoverResultResponse", corrupted)
        for field, value in (("ttlMs", -1), ("cacheScope", "shared"), ("supportedVersions", "2026-07-28")):
            with self.subTest(field=field, value=value):
                corrupted = copy.deepcopy(valid)
                corrupted["result"][field] = value
                with self.assertRaises(ValidationError):
                    validate("DiscoverResultResponse", corrupted)


class OfficialSdkTest(unittest.IsolatedAsyncioTestCase):
    async def test_official_sdk_discovers_and_uses_server(self):
        async def scenario():
            with tempfile.TemporaryDirectory(prefix="opsd-mcp-sdk-") as workspace:
                params = StdioServerParameters(
                    command=str(APP_ROOT / "bin/opsd-mcp"), cwd=workspace, env=server_environment(workspace),
                )
                async with Client(params, mode="2026-07-28", read_timeout_seconds=TIMEOUT) as client:
                    self.assertEqual("2026-07-28", client.protocol_version)
                    self.assertIsNone(client.session.initialize_result, "SDK unexpectedly fell back to legacy initialization")
                    discovery = await client.session.discover()
                    self.assertEqual(["2026-07-28"], discovery.supported_versions)
                    tools = await client.list_tools()
                    self.assertIn("verify-config", [tool.name for tool in tools.tools])
                    self.assertIn("opsd://contract", [str(r.uri) for r in (await client.list_resources()).resources])
                    self.assertEqual([], (await client.list_resource_templates()).resource_templates)
                    self.assertIn("verify-config", [p.name for p in (await client.list_prompts()).prompts])
                    contract = await client.read_resource("opsd://contract")
                    self.assertIn("OPSd", json.loads(contract.contents[0].text)["name"])
                    prompt = await client.get_prompt("verify-config", {"manifest_path": "demo.yaml"})
                    self.assertTrue(prompt.messages)
                    refused = await client.call_tool("remove-resource", {
                        "resource": "database", "manifest_path": "demo.yaml", "resource_id": "db-main",
                    })
                    self.assertTrue(refused.is_error)
                    self.assertEqual([], list(Path(workspace).iterdir()))
                    with self.assertRaises(MCPError) as caught:
                        await client.read_resource("opsd://missing")
                    self.assertEqual(-32602, caught.exception.code)
                    self.assertTrue((await client.list_tools()).tools)
        # Bound the complete session as well as each RPC; the SDK owns subprocess cleanup.
        await asyncio.wait_for(scenario(), timeout=30)


if __name__ == "__main__":
    unittest.main()
