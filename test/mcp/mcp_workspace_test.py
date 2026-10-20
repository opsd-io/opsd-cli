"""Official-SDK regressions for application data and workspace-owned execution."""

import asyncio
from contextlib import asynccontextmanager
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from mcp import Client, StdioServerParameters

from mcp_protocol_test import APP_ROOT, TIMEOUT, server_environment
from mcp_tool_execution_test import read_manifest, workspace_snapshot, write_workspace


@asynccontextmanager
async def workspace_client(workspace, cwd, **overrides):
    env = server_environment(workspace)
    env.update(overrides)
    if workspace is None:
        del env["OPSD_WORKSPACE_ROOT"]
    params = StdioServerParameters(command=str(APP_ROOT / "bin/opsd-mcp"), env=env, cwd=str(cwd))
    async with asyncio.timeout(30):
        async with Client(params, mode="2026-07-28", read_timeout_seconds=TIMEOUT) as client:
            yield client


class McpWorkspaceTest(unittest.IsolatedAsyncioTestCase):
    async def read_json(self, client, uri):
        result = await client.read_resource(uri)
        return json.loads(result.contents[0].text)

    async def test_default_and_separate_workspaces_read_all_resources_from_unrelated_cwd(self):
        with tempfile.TemporaryDirectory(prefix="opsd MCP contexts ") as root:
            root = Path(root)
            cwd, workspace = root / "host cwd", root / "selected workspace"
            cwd.mkdir()
            workspace.mkdir()
            (cwd / "examples").mkdir()
            (cwd / "examples/decoy.yaml").write_text("metadata: {name: cwd-decoy}")
            original_cwd = workspace_snapshot(cwd)
            examples_by_workspace = []
            for selected in (None, workspace):
                async with workspace_client(selected, cwd) as client:
                    resources = (await client.list_resources()).resources
                    for resource in resources:
                        await self.read_json(client, str(resource.uri))
                    examples = await self.read_json(client, "opsd://examples")
                    examples_by_workspace.append(examples)
                    self.assertIn("acme-cluster-prod", [entry["id"] for entry in examples["examples"]])
                    for entry in examples["examples"]:
                        self.assertEqual("app", entry["path_root"])
                        self.assertTrue((APP_ROOT / entry["path"]).is_file())
                    docs = await self.read_json(client, "opsd://docs/pointers")
                    for entry in docs["docs"]:
                        self.assertEqual("app", entry["path_root"])
                        self.assertTrue((APP_ROOT / entry["path"]).is_file())
            self.assertEqual(*examples_by_workspace)
            self.assertEqual(original_cwd, workspace_snapshot(cwd))
            self.assertEqual({}, workspace_snapshot(workspace))

    async def test_workspace_blueprints_paths_and_mutations_ignore_host_cwd(self):
        with tempfile.TemporaryDirectory(prefix="opsd MCP execution contexts ") as root:
            root = Path(root)
            workspace, cwd = root / "selected workspace", root / "host cwd"
            workspace.mkdir()
            cwd.mkdir()
            write_workspace(workspace)
            write_workspace(cwd)
            decoy = cwd / "modules/digitalocean/blueprints/kubernetes-foundation.yaml"
            decoy.write_text(decoy.read_text().replace("MCP Kubernetes Foundation", "Wrong workspace"))
            original_cwd = workspace_snapshot(cwd)
            async with workspace_client(workspace, cwd) as client:
                catalog = await self.read_json(client, "opsd://catalog/blueprints/digitalocean")
                blueprint = catalog["blueprints"][0]
                self.assertEqual("MCP Kubernetes Foundation", blueprint["title"])
                self.assertEqual("workspace", blueprint["path_root"])
                self.assertTrue((workspace / blueprint["path"]).is_file())
                listed = await client.call_tool("list-blueprints", {})
                self.assertFalse(listed.is_error, listed.content)
                self.assertIn("MCP Kubernetes Foundation", listed.structured_content["stdout"])
                rendered = await client.call_tool("render-manifest", {
                    "manifest_path": "valid.yaml", "output_dir": "generated stack",
                })
                self.assertFalse(rendered.is_error, rendered.content)
                self.assertTrue((workspace / "generated stack/main.tf").is_file())
                self.assertTrue((workspace / "opsd.lock.yaml").is_file())
                scaled = await client.call_tool("scale-compute-group", {
                    "manifest_path": "valid.yaml", "resource_id": "primary", "replicas": 2, "confirmed": True,
                })
                self.assertFalse(scaled.is_error, scaled.content)
                self.assertEqual(2, read_manifest(workspace / "valid.yaml")["spec"]["compute_groups"][0]["replicas"])
            self.assertEqual(original_cwd, workspace_snapshot(cwd))

    async def test_missing_modules_return_empty_resource_and_actionable_tool_failure(self):
        with tempfile.TemporaryDirectory(prefix="opsd MCP missing modules ") as root:
            workspace = Path(root)
            write_workspace(workspace)
            metadata = (workspace / "modules/digitalocean/opsd.yaml").read_bytes()
            shutil.rmtree(workspace / "modules")
            original = workspace_snapshot(workspace)
            async with workspace_client(workspace, workspace) as client:
                payload = await self.read_json(client, "opsd://catalog/blueprints/digitalocean")
                self.assertEqual([], payload["blueprints"])
                for name, arguments in (("list-blueprints", {}), ("validate-manifest", {"manifest_path": "valid.yaml"})):
                    result = await client.call_tool(name, arguments)
                    self.assertTrue(result.is_error)
                    self.assertIn("opsd modules sync", result.structured_content["stderr"])
                    self.assertFalse(result.structured_content["timedOut"])
                    self.assertEqual(original, workspace_snapshot(workspace))
                self.assertTrue((await client.list_tools()).tools)
                # Metadata alone is not a prepared module catalog either.
                provider = workspace / "modules/digitalocean"
                provider.mkdir(parents=True)
                (provider / "opsd.yaml").write_bytes(metadata)
                original = workspace_snapshot(workspace)
                result = await client.call_tool("list-blueprints", {})
                self.assertTrue(result.is_error)
                self.assertIn("opsd modules sync", result.structured_content["stderr"])
                self.assertEqual(original, workspace_snapshot(workspace))

    async def test_cached_modules_are_consistent_between_resources_and_execution(self):
        with tempfile.TemporaryDirectory(prefix="opsd MCP cached modules ") as root:
            workspace = Path(root)
            write_workspace(workspace)
            provider = workspace / "modules/digitalocean"
            for version in ("v1.0.0", "v2.0.0"):
                cached = workspace / ".opsd/cache/releases/digitalocean" / version / "modules/digitalocean"
                shutil.copytree(provider, cached)
                blueprint = cached / "blueprints/kubernetes-foundation.yaml"
                blueprint.write_text(blueprint.read_text().replace("MCP Kubernetes Foundation", version))
                if version == "v1.0.0":
                    metadata = cached / "opsd.yaml"
                    metadata.write_text(json.dumps({"profiles": {"compute": {"kubernetes": ["obsolete-profile"]}}, "addons": {}}))
            shutil.rmtree(workspace / "modules")
            async with workspace_client(workspace, workspace) as client:
                catalog = await self.read_json(client, "opsd://catalog/blueprints/digitalocean")
                self.assertEqual("v2.0.0", catalog["blueprints"][0]["title"])
                listed = await client.call_tool("list-blueprints", {})
                self.assertFalse(listed.is_error, listed.content)
                self.assertIn("v2.0.0", listed.structured_content["stdout"])
                validated = await client.call_tool("validate-manifest", {"manifest_path": "valid.yaml"})
                self.assertFalse(validated.is_error, validated.content)

    async def test_current_profile_and_explicit_profile_override_use_selected_workspace(self):
        with tempfile.TemporaryDirectory(prefix="opsd MCP profiles ") as root:
            workspace = Path(root)
            write_workspace(workspace)
            config = workspace / ".opsd/config"
            config.write_text(json.dumps({"current_profile": "unconfigured", "profiles": {
                "unconfigured": {}, "selected": {"provider": "digitalocean"}, "unsupported": {"provider": "aws"},
            }}))
            original = workspace_snapshot(workspace)
            async with workspace_client(workspace, workspace) as client:
                result = await client.call_tool("list-blueprints", {})
                self.assertTrue(result.is_error)
                self.assertIn("No profile selected", result.structured_content["stderr"])
            async with workspace_client(workspace, workspace, OPSD_PROFILE="selected") as client:
                result = await client.call_tool("list-blueprints", {})
                self.assertFalse(result.is_error, result.content)
            async with workspace_client(workspace, workspace, OPSD_PROFILE="unsupported") as client:
                result = await client.call_tool("list-blueprints", {})
                self.assertTrue(result.is_error)
                self.assertIn("Provider aws is not supported", result.structured_content["stderr"])
            self.assertEqual(original, workspace_snapshot(workspace))

    async def test_unsynchronized_modules_refuse_render_before_output_changes(self):
        with tempfile.TemporaryDirectory(prefix="opsd MCP stale modules ") as root:
            workspace = Path(root)
            write_workspace(workspace)
            (workspace / "opsd.lock.yaml").write_text(json.dumps({"provider_modules": {
                "provider": "digitalocean", "repo": "local-workspace", "version": "local-workspace",
                "commit": "unknown", "tree_sha256": "incorrect-tree-digest",
            }}))
            original = workspace_snapshot(workspace)
            async with workspace_client(workspace, workspace) as client:
                result = await client.call_tool("render-manifest", {
                    "manifest_path": "valid.yaml", "output_dir": "generated",
                })
                self.assertTrue(result.is_error)
                self.assertIn("Synchronized modules changed", result.structured_content["stderr"])
                self.assertEqual(original, workspace_snapshot(workspace))
