"""Live CLI/MCP setup check using documented commands and public module sources.

Run explicitly: this downloads real repositories/charts and needs network access.
It uses no cloud credentials and never applies infrastructure.
"""

import asyncio
import json
import os
import signal
import subprocess
from pathlib import Path
import tempfile
import unittest

from real_workflow import APP_ROOT, PIN, run, tool_environment
from mcp import Client, StdioServerParameters


class DocumentedSetupTest(unittest.IsolatedAsyncioTestCase):
    async def test_profile_catalog_cli_and_generated_mcp_connection(self):
        env = tool_environment()
        # The latest published provider release still generates obsolete layers.
        # Keep this aligned with the compatible revision documented in Setup.
        env["OPSD_MODULES_DIGITALOCEAN_REF"] = PIN["provider_commit"]
        with tempfile.TemporaryDirectory(prefix="opsd documented setup ") as temporary:
            root = Path(temporary)
            workspace, host = root / "workspace", root / "host cwd"
            workspace.mkdir()
            host.mkdir()
            env.update(OPSD_APP_ROOT=str(APP_ROOT), OPSD_WORKSPACE_ROOT=str(workspace))
            launcher = str(APP_ROOT / "bin/opsd")

            def cli(*arguments, stdin=None):
                print("CLI:", arguments[0], arguments[1] if len(arguments) > 1 else "", flush=True)
                # Profile prompts accept blank defaults; the isolated profile has no token.
                process = subprocess.Popen([launcher, *arguments], stdin=subprocess.PIPE,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           text=True, env=env, cwd=host, start_new_session=True)
                try:
                    stdout, stderr = process.communicate(input=stdin, timeout=180)
                except BaseException:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=5)
                    raise
                self.assertEqual(0, process.returncode, f"{arguments}\n{stdout}\n{stderr}")
                return stdout

            self.assertTrue(cli("version").strip())
            cli("config", "profile", "create", "work", stdin="\n\n\n")
            cli("config", "profile", "use", "work")
            self.assertIn("work", cli("config", "profile", "current"))
            self.assertIn("digitalocean", cli("config", "profile", "show", "work"))
            self.assertIn("kubernetes-foundation", cli("list", "blueprints"))
            cli("describe", "blueprint", "kubernetes-foundation")
            manifest = str(workspace / "demo.yaml")
            cli("init", "blueprint", "kubernetes-foundation", manifest, "--variant", "kubernetes")
            cli("validate", "manifest", manifest)
            cli("render", "manifest", manifest, "--output", str(workspace / "cli-smoke"))
            # The initialized blueprint has placeholder GitOps input. Use the documented
            # shipped example to exercise a configured Argo CD render without cloud access.
            platform_manifest = str(workspace / "platform-demo.yaml")
            example = (APP_ROOT / "examples/kubernetes-environment.yaml").read_text()
            # Setup asks users to choose a concrete version before schema validation.
            self.assertIn("kubernetes_version: latest", example)
            Path(platform_manifest).write_text(example.replace("kubernetes_version: latest",
                                                             "kubernetes_version: 1.33.0-do.0"))
            cli("modules", "sync", platform_manifest)
            cli("render", "manifest", platform_manifest, "--output", str(workspace / "cli-platform"), "--include-platform")
            self.assertTrue((workspace / "cli-platform/platform/helm/argocd.yaml").is_file())
            cli("validate", "manifest", platform_manifest, "--platform")
            online_env = env.copy()
            env.update(HTTP_PROXY="http://127.0.0.1:1", HTTPS_PROXY="http://127.0.0.1:1",
                       ALL_PROXY="http://127.0.0.1:1", NO_PROXY="")
            cli("validate", "manifest", platform_manifest, "--platform", "--offline")
            env.clear()
            env.update(online_env)

            generated = json.loads(run(str(APP_ROOT / "bin/opsd-mcp"), "config",
                                       "--workspace-root", str(workspace), env=env, cwd=host))
            entry = generated["mcpServers"]["opsd"]
            for value in (entry["command"], entry["env"]["RUBY_BIN"]):
                self.assertTrue(Path(value).is_absolute())
            server_env = dict(entry["env"], PATH=env["PATH"])
            params = StdioServerParameters(command=entry["command"], env=server_env, cwd=str(host))
            async with asyncio.timeout(180):
                async with Client(params, mode="2026-07-28", read_timeout_seconds=75) as client:
                    self.assertEqual(["2026-07-28"], (await client.session.discover()).supported_versions)
                    self.assertTrue((await client.list_tools()).tools)
                    await client.read_resource("opsd://contract")
                    for name, arguments in [
                        ("validate-manifest", {"manifest_path": "demo.yaml"}),
                        ("render-manifest", {"manifest_path": "demo.yaml", "output_dir": "mcp-smoke"}),
                    ]:
                        result = await client.call_tool(name, arguments)
                        self.assertFalse(result.is_error, result.content)
                        self.assertEqual(0, result.structured_content["exitCode"])
                    before = (workspace / "demo.yaml").read_bytes()
                    refused = await client.call_tool("scale-compute-group", {
                        "manifest_path": "demo.yaml", "resource_id": "cluster", "replicas": 2,
                    })
                    self.assertTrue(refused.is_error)
                    self.assertEqual(before, (workspace / "demo.yaml").read_bytes())
                    missing = await client.call_tool("validate-manifest", {"manifest_path": "missing.yaml"})
                    self.assertTrue(missing.is_error)
                    recovered = await client.call_tool("validate-manifest", {"manifest_path": "demo.yaml"})
                    self.assertFalse(recovered.is_error, recovered.content)
            for output in ("cli-smoke", "mcp-smoke"):
                for artifact in ("main.tf", "opsd.manifest.yaml", "opsd.lock.yaml"):
                    self.assertTrue((workspace / output / artifact).is_file(), (output, artifact))
            self.assertEqual([], list(host.iterdir()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
