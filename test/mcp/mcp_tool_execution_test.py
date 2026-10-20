"""SDK-driven tests of real OPSd CLI execution and filesystem effects."""

import asyncio
import copy
import os
import subprocess
from contextlib import asynccontextmanager
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

from mcp import Client, MCPError, StdioServerParameters

from mcp_protocol_test import APP_ROOT, TIMEOUT, WireServer, request, server_environment


def write_workspace(workspace):
    """Use local provider fixtures only: no cloud credentials, remote modules, or personal cache."""
    provider = workspace / "modules/digitalocean"
    (provider / "blueprints").mkdir(parents=True)
    (provider / "opsd.yaml").write_text(json.dumps({
        "profiles": {"compute": {"kubernetes": ["s-2vcpu-4gb", "s-4vcpu-8gb"]}}, "addons": {},
    }))
    (provider / "blueprints/kubernetes-foundation.yaml").write_text(json.dumps({
        "id": "kubernetes-foundation", "title": "MCP Kubernetes Foundation", "provider": "digitalocean",
        "variants": [{"id": "kubernetes", "title": "Kubernetes", "family": "kubernetes",
                      "stack": "kubernetes-foundation"}],
    }))
    (workspace / ".opsd").mkdir()
    (workspace / ".opsd/config").write_text(json.dumps({
        "current_profile": "mcp-test", "profiles": {"mcp-test": {"provider": "digitalocean"}},
    }))
    source = (APP_ROOT / "examples/kubernetes-environment.yaml").read_text()
    (workspace / "valid.yaml").write_text(source)
    invalid = source.replace("apiVersion: opsd.io/v2alpha1", "apiVersion: opsd.io/unsupported")
    assert invalid != source
    (workspace / "invalid.yaml").write_text(invalid)
    return source


@asynccontextmanager
async def client_workspace():
    with tempfile.TemporaryDirectory(prefix="opsd MCP execution ") as directory:
        workspace = Path(directory)
        write_workspace(workspace)
        params = StdioServerParameters(
            command=str(APP_ROOT / "bin/opsd-mcp"), env=server_environment(workspace), cwd=directory,
        )
        async with asyncio.timeout(30):
            async with Client(params, mode="2026-07-28", read_timeout_seconds=TIMEOUT) as client:
                yield client, workspace


class McpToolExecutionTest(unittest.IsolatedAsyncioTestCase):
    def assert_success(self, response):
        self.assertFalse(response.is_error, response.content)
        output = response.structured_content
        self.assertEqual(0, output["exitCode"])
        self.assertFalse(output["timedOut"])
        return output

    def assert_failure(self, response):
        self.assertTrue(response.is_error, response.content)
        output = response.structured_content
        self.assertNotEqual(0, output["exitCode"])
        self.assertFalse(output["timedOut"])
        return output

    async def test_blueprint_tools_return_actual_catalog_and_description(self):
        async with client_workspace() as (client, _):
            output = self.assert_success(await client.call_tool("list-blueprints", {}))
            self.assertIn("Blueprint Catalog", output["stdout"])
            self.assertIn("MCP Kubernetes Foundation", output["stdout"])
            self.assertIn("kubernetes-foundation", output["stdout"])
            output = self.assert_success(await client.call_tool("describe-blueprint", {
                "blueprint": "kubernetes-foundation", "variant": "kubernetes",
            }))
            self.assertIn("ID: kubernetes-foundation", output["stdout"])
            self.assertIn("kubernetes", output["stdout"])

    async def test_validation_reports_missing_and_invalid_manifests_and_recovers(self):
        async with client_workspace() as (client, workspace):
            original = (workspace / "valid.yaml").read_bytes()
            output = self.assert_failure(await client.call_tool("validate-manifest", {"manifest_path": "missing.yaml"}))
            self.assertIn("Manifest file not found", output["stderr"])
            output = self.assert_failure(await client.call_tool("validate-manifest", {"manifest_path": "invalid.yaml"}))
            self.assertIn("Validation failed", output["stderr"])
            output = self.assert_success(await client.call_tool("validate-manifest", {"manifest_path": "valid.yaml"}))
            self.assertIn("Manifest is valid", output["stdout"])
            self.assertEqual(original, (workspace / "valid.yaml").read_bytes())

    async def test_render_creates_real_artifacts_and_export_archives_them(self):
        async with client_workspace() as (client, workspace):
            rendered = "generated $(touch render-injected); stack"
            output = self.assert_success(await client.call_tool("render-manifest", {
                "manifest_path": "valid.yaml", "output_dir": rendered,
            }))
            self.assertIn("Rendered stack:", output["stdout"])
            target = workspace / rendered
            for name in ("main.tf", "variables.tf", "outputs.tf", "opsd.auto.tfvars", "opsd.manifest.yaml",
                         "opsd.lock.yaml", "README.md", "scenario.json", "opsd.layers.yaml"):
                self.assertTrue((target / name).is_file(), name)
                self.assertGreater((target / name).stat().st_size, 0, name)
            self.assertEqual("kubernetes-foundation", json.loads((target / "scenario.json").read_text())["id"])
            original_main = (target / "main.tf").read_bytes()
            self.assertIn(b"acme-cluster-prod", (target / "opsd.auto.tfvars").read_bytes())
            # The CLI's refusal to overwrite must be visible to MCP too.
            self.assert_failure(await client.call_tool("render-manifest", {
                "manifest_path": "valid.yaml", "output_dir": rendered,
            }))
            self.assertEqual(original_main, (target / "main.tf").read_bytes())
            archive = "handoff $(touch archive-injected).tar.gz"
            self.assert_success(await client.call_tool("export-exit-pack", {"rendered_dir": rendered, "output_path": archive}))
            with tarfile.open(workspace / archive) as bundle:
                self.assertEqual(original_main, bundle.extractfile("exit-pack/main.tf").read())
                self.assertIn("exit-pack/HANDOFF.md", bundle.getnames())
            self.assertFalse((workspace / "render-injected").exists())
            self.assertFalse((workspace / "archive-injected").exists())

    async def test_paths_with_shell_syntax_and_option_like_names_are_literal(self):
        async with client_workspace() as (client, workspace):
            source = (workspace / "valid.yaml").read_text()
            for name in ("env $(touch injected); demo.yaml", "--help"):
                with self.subTest(name=name):
                    (workspace / name).write_text(source)
                    output = self.assert_success(await client.call_tool("validate-manifest", {"manifest_path": name}))
                    self.assertIn("Manifest is valid:", output["stdout"])
                    self.assertIn(name, output["stdout"])
            self.assertFalse((workspace / "injected").exists())

    async def test_verification_tools_execute_and_report_rejected_inputs(self):
        async with client_workspace() as (client, workspace):
            self.assert_success(await client.call_tool("verify-config", {"manifest_path": "valid.yaml"}))
            plan = {"format_version": "1.0", "resource_changes": []}
            (workspace / "plan.json").write_text(json.dumps(plan))
            output = self.assert_success(await client.call_tool("verify-plan", {"plan_path": "plan.json"}))
            self.assertIn("Plan is supported", output["stdout"])
            (workspace / "plan.json").write_text("{broken")
            self.assert_failure(await client.call_tool("verify-plan", {"plan_path": "plan.json"}))
            snapshot = {"provider": "digitalocean", "provider_version": "v1.0.0", "tofu_version": "1.10.0", "policy_version": "2"}
            (workspace / "lifecycle.json").write_text(json.dumps(snapshot))
            output = self.assert_success(await client.call_tool("verify-lifecycle", {"snapshot_path": "lifecycle.json"}))
            self.assertIn("Lifecycle is compatible", output["stdout"])
            snapshot["provider_version"] = "v9.9.9"
            (workspace / "lifecycle.json").write_text(json.dumps(snapshot))
            self.assert_failure(await client.call_tool("verify-lifecycle", {"snapshot_path": "lifecycle.json"}))

    async def test_mutations_refuse_missing_false_and_invalid_confirmation_without_side_effects(self):
        async with client_workspace() as (client, workspace):
            original = workspace_snapshot(workspace)
            tools = {
                "add-compute-group": {"id": "new", "role": "cluster", "type": "cluster", "profile": "s-2vcpu-4gb"},
                "resize-compute-group": {"resource_id": "primary", "profile": "s-2vcpu-4gb"},
                "scale-compute-group": {"resource_id": "primary", "replicas": 2},
                "attach-compute-group": {"resource_id": "primary", "load_balancer_id": "lb"},
                "detach-compute-group": {"resource_id": "primary", "load_balancer_id": "lb"},
                "remove-resource": {"resource": "compute-group", "resource_id": "primary"},
            }
            for name, arguments in tools.items():
                for confirmation in ({}, {"confirmed": False}):
                    with self.subTest(tool=name, confirmation=confirmation):
                        result = await client.call_tool(name, dict(arguments, manifest_path="valid.yaml", **confirmation))
                        self.assertTrue(result.is_error)
                        self.assertIn("requires explicit confirmation", result.content[0].text)
                        self.assertEqual(original, workspace_snapshot(workspace))
                for invalid in ("true", "false", 1, 0, None, [], {}):
                    with self.subTest(tool=name, confirmed=invalid):
                        with self.assertRaises(MCPError) as caught:
                            await client.call_tool(name, dict(arguments, manifest_path="valid.yaml", confirmed=invalid))
                        self.assertEqual(-32602, caught.exception.code)
                        self.assertEqual(original, workspace_snapshot(workspace))

    async def test_confirmed_mutations_have_only_the_requested_effect(self):
        async with client_workspace() as (client, workspace):
            manifest = workspace / "env $(touch injected); approved.yaml"
            data = read_manifest(workspace / "valid.yaml")
            data["spec"]["load_balancers"] = [{
                "id": "lb", "visibility": "public", "protocol": "http", "port": 80, "target_port": 8080,
            }]
            manifest.write_text(json.dumps(data))
            original_workspace = workspace_snapshot(workspace)
            operations = [
                ("add-compute-group", {"id": "new", "role": "cluster", "type": "cluster", "profile": "s-2vcpu-4gb"}),
                ("resize-compute-group", {"resource_id": "new", "profile": "s-4vcpu-8gb"}),
                ("scale-compute-group", {"resource_id": "new", "replicas": 3}),
                ("attach-compute-group", {"resource_id": "new", "load_balancer_id": "lb"}),
                ("detach-compute-group", {"resource_id": "new", "load_balancer_id": "lb"}),
                ("remove-resource", {"resource": "compute-group", "resource_id": "new"}),
            ]
            expected = copy.deepcopy(data)
            for name, arguments in operations:
                with self.subTest(tool=name):
                    result = await client.call_tool(name, dict(arguments, manifest_path=manifest.name, confirmed=True))
                    self.assert_success(result)
                    groups = expected["spec"]["compute_groups"]
                    if name == "add-compute-group":
                        groups.append(dict(arguments, replicas=1))
                    elif name == "resize-compute-group":
                        groups[-1]["profile"] = arguments["profile"]
                    elif name == "scale-compute-group":
                        groups[-1]["replicas"] = 3
                    elif name == "attach-compute-group":
                        groups[-1]["attach_to"] = ["lb"]
                    elif name == "detach-compute-group":
                        del groups[-1]["attach_to"]
                    else:
                        groups.pop()
                    self.assertEqual(expected, read_manifest(manifest))
                    snapshot = workspace_snapshot(workspace)
                    snapshot[manifest.name] = original_workspace[manifest.name]
                    self.assertEqual(original_workspace, snapshot)
            # Approval applies only to its own call; the server must not remember it.
            refused = await client.call_tool("scale-compute-group", {
                "manifest_path": manifest.name, "resource_id": "primary", "replicas": 5,
            })
            self.assertTrue(refused.is_error)
            self.assertEqual(expected, read_manifest(manifest))
            original = manifest.read_bytes()
            failure = await client.call_tool("scale-compute-group", {
                "manifest_path": manifest.name, "resource_id": "primary", "replicas": 0, "confirmed": True,
            })
            self.assert_failure(failure)
            self.assertEqual(original, manifest.read_bytes())


def workspace_snapshot(workspace):
    return {str(path.relative_to(workspace)): path.read_bytes() if path.is_file() else None
            for path in workspace.rglob("*")}


def read_manifest(path):
    # Use the CLI's Ruby YAML parser without adding a Python YAML dependency.
    output = subprocess.check_output([
        os.environ["RUBY_BIN"], "-ryaml", "-rjson", "-e",
        "puts JSON.generate(YAML.safe_load(File.read(ARGV.fetch(0))))", str(path),
    ], timeout=TIMEOUT)
    return json.loads(output)


class McpConfirmationDiscoveryTest(unittest.TestCase):
    def test_discovery_classifies_effects_and_declares_confirmation(self):
        with WireServer() as server:
            result = server.exchange(request("tools/list"), "ListToolsResultResponse")["result"]
            for tool in result["tools"]:
                effect = tool["_meta"]["io.opsd/effect"]
                required = tool["_meta"]["io.opsd/requiresConfirmation"]
                self.assertEqual(effect in ("manifest-mutation", "dependency-sync"), required)
                self.assertEqual(effect == "read-only", tool["annotations"]["readOnlyHint"])
                self.assertEqual(effect != "read-only", tool["annotations"]["destructiveHint"])
                if required:
                    prop = tool["inputSchema"]["properties"]["confirmed"]
                    self.assertEqual("boolean", prop["type"])
                    self.assertIn("explicit user approval", prop["description"])
                    self.assertIn("Requires explicit user confirmation", tool["description"])
                else:
                    self.assertNotIn("confirmed", tool["inputSchema"]["properties"])
                if tool["name"] in ("render-manifest", "export-exit-pack"):
                    self.assertEqual("generated-files", effect)

    def test_top_level_confirmation_cannot_bypass_argument_gate(self):
        with WireServer() as server:
            workspace = Path(server.workspace.name)
            write_workspace(workspace)
            original = workspace_snapshot(workspace)
            for confirmation in ({}, {"confirmed": False}):
                response = server.exchange(request("tools/call", name="scale-compute-group", confirmed=True,
                    arguments=dict(manifest_path="valid.yaml", resource_id="primary", replicas=4, **confirmation)),
                    "CallToolResultResponse")
                self.assertTrue(response["result"]["isError"])
                self.assertEqual(original, workspace_snapshot(workspace))
