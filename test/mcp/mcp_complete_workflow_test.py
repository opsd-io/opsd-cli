"""A combined MCP scenario, reused unchanged for checkout and extracted bundles."""

import json
import os
from pathlib import Path
import tarfile
import unittest

from mcp import MCPError

from mcp_platform_workflow_test import platform_workspace
from mcp_tool_execution_test import read_manifest, workspace_snapshot


class McpCompleteWorkflowTest(unittest.IsolatedAsyncioTestCase):
    async def test_discover_prepare_mutate_validate_render_and_export(self):
        async with platform_workspace() as (client, workspace, _, _, _):
            transcript = []

            async def call(name, arguments, success=True):
                result = await client.call_tool(name, arguments)
                transcript.append({"tool": name, "arguments": arguments,
                                   "output": result.structured_content,
                                   "content": [block.model_dump(mode="json") for block in result.content]})
                self.assertEqual(not success, result.is_error, result.content)
                return result

            try:
                discovery = await client.session.discover()
                self.assertEqual(["2026-07-28"], discovery.supported_versions)
                names = {tool.name for tool in (await client.list_tools()).tools}
                self.assertTrue({"modules-sync", "validate-manifest", "render-manifest", "scale-compute-group"} <= names)
                for resource in (await client.list_resources()).resources:
                    payload = await client.read_resource(str(resource.uri))
                    json.loads(payload.contents[0].text)
                prompt = await client.get_prompt("prepare-platform", {
                    "manifest_path": "valid.yaml", "output_dir": "rendered platform",
                })
                self.assertIn("modules-sync", prompt.messages[0].content.text)
                original = workspace_snapshot(workspace)
                await call("scale-compute-group", {
                    "manifest_path": "valid.yaml", "resource_id": "primary", "replicas": 2,
                }, success=False)
                self.assertEqual(original, workspace_snapshot(workspace))
                with self.assertRaises(MCPError):
                    await client.call_tool("scale-compute-group", {
                        "manifest_path": "valid.yaml", "resource_id": "primary", "replicas": "two", "confirmed": True,
                    })
                self.assertEqual(original, workspace_snapshot(workspace))
                await call("validate-manifest", {"manifest_path": "missing.yaml"}, success=False)
                await call("modules-sync", {"manifest_path": "valid.yaml", "confirmed": True})
                lock_path = workspace / "opsd.lock.yaml"
                pinned = lock_path.read_bytes()
                before = read_manifest(workspace / "valid.yaml")
                await call("scale-compute-group", {
                    "manifest_path": "valid.yaml", "resource_id": "primary", "replicas": 2, "confirmed": True,
                })
                before["spec"]["compute_groups"][0]["replicas"] = 2
                self.assertEqual(before, read_manifest(workspace / "valid.yaml"))
                await call("validate-manifest", {"manifest_path": "valid.yaml"})
                await call("render-manifest", {
                    "manifest_path": "valid.yaml", "output_dir": "rendered platform", "include_platform": True,
                })
                rendered = workspace / "rendered platform"
                self.assertIn("chart-fixture", (rendered / "platform/helm/argocd.yaml").read_text())
                self.assertTrue((rendered / "main.tf").is_file())
                self.assertEqual(before, read_manifest(rendered / "opsd.manifest.yaml"))
                self.assertEqual(pinned, lock_path.read_bytes())
                artifact = workspace_snapshot(rendered)
                await call("render-manifest", {
                    "manifest_path": "valid.yaml", "output_dir": "rendered platform", "include_platform": True,
                }, success=False)
                self.assertEqual(artifact, workspace_snapshot(rendered))
                await call("validate-manifest", {
                    "manifest_path": "valid.yaml", "platform": True, "offline": True,
                }, success=False)
                self.assertEqual(pinned, lock_path.read_bytes())
                await call("export-exit-pack", {"rendered_dir": "rendered platform", "output_path": "handoff.tar.gz"})
                with tarfile.open(workspace / "handoff.tar.gz") as archive:
                    self.assertEqual((rendered / "main.tf").read_bytes(), archive.extractfile("exit-pack/main.tf").read())
                    self.assertIn("exit-pack/HANDOFF.md", archive.getnames())
                # Approval must not carry over from the earlier mutation or synchronization.
                await call("scale-compute-group", {
                    "manifest_path": "valid.yaml", "resource_id": "primary", "replicas": 5,
                }, success=False)
                self.assertEqual(before, read_manifest(workspace / "valid.yaml"))
            except BaseException:
                if os.environ.get("OPSD_MCP_DIAGNOSTICS"):
                    diagnostics = Path(os.environ["OPSD_MCP_DIAGNOSTICS"])
                    diagnostics.mkdir(parents=True, exist_ok=True)
                    (diagnostics / "complete-workflow.json").write_text(json.dumps({
                        "transcript": transcript,
                        "files": sorted(workspace_snapshot(workspace)),
                    }, indent=2))
                raise
