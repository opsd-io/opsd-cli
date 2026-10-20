"""Real CLI workflows with local Git sources and deterministic external-tool stand-ins."""

from contextlib import asynccontextmanager
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from mcp import MCPError
from jsonschema import Draft202012Validator, ValidationError

from mcp_protocol_test import TIMEOUT, WireServer, request
from mcp_tool_execution_test import read_manifest, workspace_snapshot, write_workspace
from mcp_workspace_test import workspace_client


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.PIPE, timeout=TIMEOUT).decode().strip()


def commit_repo(repo):
    git(repo, "init", "-q", "-b", "main")
    git(repo, "add", ".")
    git(repo, "-c", "user.name=OPSd Test", "-c", "user.email=opsd@example.test", "commit", "-qm", "test fixture")
    return git(repo, "rev-parse", "HEAD")


def write_tool(path, source):
    path.write_text(f"#!{os.environ['RUBY_BIN']}\n" + source)
    path.chmod(0o755)


@asynccontextmanager
async def platform_workspace():
    with tempfile.TemporaryDirectory(prefix="opsd MCP platform ") as directory:
        root = Path(directory)
        workspace = root / "workspace"
        workspace.mkdir()
        write_workspace(workspace)
        provider = root / "provider-repo"
        shutil.move(str(workspace / "modules/digitalocean"), provider)
        provider_commit = commit_repo(provider)
        kube = root / "kubernetes-repo"
        module = kube / "modules/bootstrap/argocd"
        module.mkdir(parents=True)
        digest = hashlib.sha256(b"fixture-chart").hexdigest()
        (module / "module.yaml").write_text(json.dumps({
            "apiVersion": "opsd.io/modules/v1alpha1", "kind": "KubernetesModule",
            "metadata": {"id": "argocd", "name": "Argo CD", "description": "Local chart fixture"},
            "spec": {"layer": "bootstrap", "source": {
                "type": "helm", "repository": "https://example.invalid/charts", "chart": "argo-cd",
                "version": "1.2.3", "digest": f"sha256:{digest}",
            }, "defaults": "defaults.yaml", "schema": "schema.yaml",
                "ownership": {"type": "official", "repository": "opsd-io/modules-kubernetes"},
                "supported_providers": ["digitalocean"], "validation": {"mode": "strict"}},
        }))
        (module / "defaults.yaml").write_text("replicaCount: 1\n")
        (module / "schema.yaml").write_text("type: object\n")
        kube_commit = commit_repo(kube)
        tools = root / "tools"
        tools.mkdir()
        # These stand-ins qualify OPSd orchestration, not third-party validators.
        write_tool(tools / "helm", '''require "json"
File.open(ENV.fetch("TOOL_LOG"), "a") { |f| f.puts(JSON.generate(["helm", *ARGV])) }
case ARGV.first
when "pull"
  destination = ARGV[ARGV.index("--destination") + 1]
  File.write(File.join(destination, "argo-cd-1.2.3.tgz"), "fixture-chart")
when "template"
  puts "apiVersion: v1\\nkind: ConfigMap\\nmetadata:\\n  name: chart-fixture"
end
''')
        for tool in ("terraform", "tofu", "kubeconform"):
            write_tool(tools / tool, '''require "json"
require "fileutils"
File.open(ENV.fetch("TOOL_LOG"), "a") { |f| f.puts(JSON.generate([File.basename($0), *ARGV])) }
if ARGV.include?("init")
  directory = ARGV.find { |arg| arg.start_with?("-chdir=") }.delete_prefix("-chdir=")
  File.write(File.join(directory, ".terraform.lock.hcl"), "# fixture lock\n")
elsif ARGV.include?("mirror")
  FileUtils.mkdir_p(ARGV.last)
  File.write(File.join(ARGV.last, "fixture.zip"), "fixture")
end
''')
        env = {
            "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}", "TOOL_LOG": str(root / "tool-log.jsonl"),
            "OPSD_MODULES_DIGITALOCEAN_REPO": str(provider), "OPSD_MODULES_DIGITALOCEAN_REF": "main",
            "OPSD_MODULES_KUBERNETES_REPO": str(kube), "OPSD_MODULES_KUBERNETES_REF": "main",
        }
        async with workspace_client(workspace, root, **env) as client:
            yield client, workspace, root, provider_commit, kube_commit


class McpPlatformWorkflowTest(unittest.IsolatedAsyncioTestCase):
    def assert_success(self, result):
        self.assertFalse(result.is_error, result.content)
        self.assertEqual(0, result.structured_content["exitCode"])

    async def test_explicit_sync_platform_render_and_offline_failure_preserve_pins(self):
        async with platform_workspace() as (client, workspace, root, provider_commit, kube_commit):
            original = workspace_snapshot(workspace)
            before = await client.read_resource("opsd://catalog/blueprints/digitalocean")
            self.assertEqual([], json.loads(before.contents[0].text)["blueprints"])
            for confirmation in ({}, {"confirmed": False}):
                refused = await client.call_tool("modules-sync", dict(manifest_path="valid.yaml", **confirmation))
                self.assertTrue(refused.is_error)
                self.assertEqual(original, workspace_snapshot(workspace))
            for invalid in ("true", 1, None):
                with self.assertRaises(MCPError):
                    await client.call_tool("modules-sync", {"manifest_path": "valid.yaml", "confirmed": invalid})
                self.assertEqual(original, workspace_snapshot(workspace))
            missing = await client.call_tool("render-manifest", {
                "manifest_path": "valid.yaml", "output_dir": "missing-platform", "include_platform": True,
            })
            self.assertTrue(missing.is_error)
            self.assertEqual(original, workspace_snapshot(workspace))
            self.assert_success(await client.call_tool("modules-sync", {"manifest_path": "valid.yaml", "confirmed": True}))
            after = await client.read_resource("opsd://catalog/blueprints/digitalocean")
            self.assertEqual("kubernetes-foundation", json.loads(after.contents[0].text)["blueprints"][0]["id"])
            lock_path = workspace / "opsd.lock.yaml"
            lock = read_manifest(lock_path)
            self.assertEqual(provider_commit, lock["provider_modules"]["commit"])
            self.assertEqual(kube_commit, lock["kubernetes_modules"]["commit"])
            self.assertTrue((workspace / "modules/kubernetes/modules/bootstrap/argocd/module.yaml").is_file())
            pinned = lock_path.read_bytes()
            self.assert_success(await client.call_tool("modules-sync", {"manifest_path": "valid.yaml", "confirmed": True}))
            self.assertEqual(pinned, lock_path.read_bytes())
            self.assert_success(await client.call_tool("render-manifest", {
                "manifest_path": "valid.yaml", "output_dir": "platform output", "include_platform": True,
            }))
            rendered = workspace / "platform output"
            self.assertTrue((rendered / "main.tf").is_file())
            self.assertIn("chart-fixture", (rendered / "platform/helm/argocd.yaml").read_text())
            self.assertEqual(pinned, lock_path.read_bytes())
            (root / "tool-log.jsonl").write_text("")
            offline = await client.call_tool("validate-manifest", {
                "manifest_path": "valid.yaml", "platform": True, "offline": True,
            })
            self.assertTrue(offline.is_error)
            self.assertIn("Offline validation cache is missing", offline.structured_content["stderr"])
            self.assertEqual("", (root / "tool-log.jsonl").read_text())
            self.assertEqual(pinned, lock_path.read_bytes())
            # Cache every built-in schema requested by the actual rendered resources.
            kinds = subprocess.check_output([
                os.environ["RUBY_BIN"], "-ryaml", "-rjson", "-e",
                'puts JSON.generate(Dir.glob(ARGV[0]+"/{layers,platform}/**/*.yaml").flat_map { |p| YAML.load_stream(File.read(p)).compact }.select { |r| r.is_a?(Hash) && r["kind"] && r["apiVersion"] }.map { |r| [r["kind"], r["apiVersion"]] })',
                str(rendered),
            ], timeout=TIMEOUT)
            schemas = workspace / ".opsd/cache/kubeconform/builtin/vlatest-standalone-strict"
            schemas.mkdir(parents=True)
            for kind, version in json.loads(kinds):
                parts = version.split("/")
                suffix = parts[0] if len(parts) == 1 else f"{parts[0].split('.')[0]}-{parts[1]}"
                (schemas / f"{kind.lower()}-{suffix}.json").write_text("{}")
            # Exercise online cache preparation without real downloads, then require those caches offline.
            self.assert_success(await client.call_tool("validate-manifest", {
                "manifest_path": "valid.yaml", "platform": True, "offline": False,
            }))
            for tool in ("terraform", "tofu"):
                self.assertTrue((workspace / ".opsd/cache/iac" / tool / "providers/fixture.zip").is_file())
            self.assertEqual(pinned, lock_path.read_bytes())
            (root / "tool-log.jsonl").write_text("")
            self.assert_success(await client.call_tool("validate-manifest", {
                "manifest_path": "valid.yaml", "platform": True, "offline": True,
            }))
            calls = [json.loads(line) for line in (root / "tool-log.jsonl").read_text().splitlines()]
            for tool in ("terraform", "tofu"):
                init = next(call for call in calls if call[0] == tool and "init" in call)
                self.assertIn("-lockfile=readonly", init)
                self.assertTrue(any(arg.startswith("-plugin-dir=") for arg in init))
            self.assertTrue(any(call[0] == "kubeconform" for call in calls))
            self.assertFalse(any(call[:2] == ["helm", "pull"] for call in calls))
            self.assertEqual(pinned, lock_path.read_bytes())

    async def test_explicit_update_changes_pins_and_refuses_local_module_edits(self):
        async with platform_workspace() as (client, workspace, root, _, _):
            self.assert_success(await client.call_tool("modules-sync", {"manifest_path": "valid.yaml", "confirmed": True}))
            old = read_manifest(workspace / "opsd.lock.yaml")
            kube = root / "kubernetes-repo"
            (kube / "new.txt").write_text("new upstream version\n")
            git(kube, "add", ".")
            git(kube, "-c", "user.name=OPSd Test", "-c", "user.email=opsd@example.test", "commit", "-qm", "new fixture revision")
            self.assert_success(await client.call_tool("modules-sync", {"manifest_path": "valid.yaml", "confirmed": True}))
            self.assertEqual(old, read_manifest(workspace / "opsd.lock.yaml"))
            self.assert_success(await client.call_tool("modules-sync", {
                "manifest_path": "valid.yaml", "confirmed": True, "update": True,
            }))
            new = read_manifest(workspace / "opsd.lock.yaml")
            self.assertNotEqual(old["kubernetes_modules"]["commit"], new["kubernetes_modules"]["commit"])
            self.assertEqual(git(kube, "rev-parse", "HEAD"), new["kubernetes_modules"]["commit"])
            (workspace / "modules/kubernetes/new.txt").write_text("client edit\n")
            snapshot = workspace_snapshot(workspace)
            failed = await client.call_tool("modules-sync", {"manifest_path": "valid.yaml", "confirmed": True, "update": True})
            self.assertTrue(failed.is_error)
            self.assertIn("local changes", failed.structured_content["stderr"])
            self.assertEqual(snapshot, workspace_snapshot(workspace))

    async def test_optional_mutation_arguments_reach_manifest_and_unknown_arguments_fail(self):
        from mcp_tool_execution_test import client_workspace
        async with client_workspace() as (client, workspace):
            manifest = read_manifest(workspace / "valid.yaml")
            manifest["spec"]["load_balancers"] = [{
                "id": "lb", "visibility": "public", "protocol": "http", "port": 80, "target_port": 8080,
            }]
            (workspace / "valid.yaml").write_text(json.dumps(manifest))
            result = await client.call_tool("add-compute-group", {
                "manifest_path": "valid.yaml", "id": "new", "type": "cluster", "role": "cluster",
                "profile": "s-2vcpu-4gb", "replicas": 2, "image": "test-image", "port": 8080,
                "links": ["primary"], "attach_to": ["lb"], "confirmed": True,
            })
            self.assert_success(result)
            group = read_manifest(workspace / "valid.yaml")["spec"]["compute_groups"][-1]
            self.assertEqual(2, group["replicas"])
            self.assertEqual("test-image", group["image"])
            self.assertEqual(8080, group["port"])
            self.assertEqual(["primary"], group["links"])
            self.assertEqual(["lb"], group["attach_to"])
            snapshot = workspace_snapshot(workspace)
            for extra in ({"platform": "true"}, {"unsupported": True}):
                with self.assertRaises(MCPError) as caught:
                    await client.call_tool("validate-manifest", dict(manifest_path="valid.yaml", **extra))
                self.assertEqual(-32602, caught.exception.code)
            for invalid in ({"port": "8080"}, {"links": [1]}, {"attach_to": "lb"}):
                with self.assertRaises(MCPError) as caught:
                    await client.call_tool("add-compute-group", dict(
                        manifest_path="valid.yaml", id="bad", type="cluster", role="cluster",
                        profile="s-2vcpu-4gb", confirmed=True, **invalid,
                    ))
                self.assertEqual(-32602, caught.exception.code)
            self.assertEqual(snapshot, workspace_snapshot(workspace))


class McpWorkflowDiscoveryTest(unittest.TestCase):
    def test_option_schemas_and_workflow_prompt_are_discoverable(self):
        with WireServer() as server:
            tools = server.exchange(request("tools/list"), "ListToolsResultResponse")["result"]["tools"]
            by_name = {tool["name"]: tool for tool in tools}
            for name, flags in {"modules-sync": ["update"], "render-manifest": ["include_platform"],
                                "validate-manifest": ["platform", "offline"]}.items():
                schema = by_name[name]["inputSchema"]
                for flag in flags:
                    self.assertEqual("boolean", schema["properties"][flag]["type"])
                    self.assertFalse(schema["properties"][flag]["default"])
                sample = {"manifest_path": "demo.yaml"}
                if name == "render-manifest":
                    sample["output_dir"] = "output"
                Draft202012Validator(schema).validate(dict(sample, **{flags[0]: True}))
                for flag in flags:
                    with self.assertRaises(ValidationError):
                        Draft202012Validator(schema).validate(dict(sample, **{flag: "true"}))
                    response = server.exchange(request("tools/call", name=name,
                        arguments=dict(sample, **{flag: "true"})), "JSONRPCErrorResponse")
                    self.assertEqual(-32602, response["error"]["code"])
            self.assertEqual("dependency-sync", by_name["modules-sync"]["_meta"]["io.opsd/effect"])
            self.assertTrue(by_name["modules-sync"]["annotations"]["openWorldHint"])
            result = server.exchange(request("prompts/get", name="prepare-platform", arguments={
                "manifest_path": "demo.yaml", "output_dir": "platform",
            }), "GetPromptResultResponse")["result"]
            text = result["messages"][0]["content"]["text"]
            for keyword in ("modules-sync", "include_platform=true", "offline=true", "explicit user approval"):
                self.assertIn(keyword, text)
