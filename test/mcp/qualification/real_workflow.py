"""Cloud-free qualification with real Git, Helm, Terraform, OpenTofu, and kubeconform."""

import asyncio
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import unittest

TEST_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TEST_ROOT))
from mcp import Client, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp_protocol_test import APP_ROOT, server_environment
from mcp_tool_execution_test import read_manifest, write_workspace
from mcp_platform_workflow_test import commit_repo

SOURCE_ROOT = TEST_ROOT.parents[1]
PIN = json.loads((TEST_ROOT / "fixtures/real-tools.json").read_text())


def run(*command, cwd=None, env=None, timeout=120):
    process = subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=5)
        raise
    if process.returncode:
        raise AssertionError(f"{' '.join(map(str, command))}\n{stdout}\n{stderr}")
    return stdout


def tool_environment():
    env = server_environment("unused")
    directories = []
    for tool in ("terraform", "tofu", "helm", "kubeconform"):
        path = shutil.which(tool)
        if not path:
            raise AssertionError(f"Real MCP qualification requires {tool} from .tool-versions")
        # Resolve asdf shims while still in the source project; the host cwd is deliberately unrelated.
        if "/shims/" in path and shutil.which("asdf"):
            path = run("asdf", "which", tool, cwd=SOURCE_ROOT).strip()
        directories.append(str(Path(path).parent))
    env["PATH"] = os.pathsep.join(directories + [env["PATH"]])
    expected = dict(line.split() for line in (SOURCE_ROOT / ".tool-versions").read_text().splitlines() if line.strip())
    actual = {
        "terraform": json.loads(run("terraform", "version", "-json", env=env))["terraform_version"],
        "opentofu": json.loads(run("tofu", "version", "-json", env=env))["terraform_version"],
        "helm": run("helm", "version", "--short", env=env).strip().split("+")[0].removeprefix("v"),
        "kubeconform": run("kubeconform", "-v", env=env).strip().removeprefix("v"),
    }
    if actual != expected:
        raise AssertionError(f"Tool versions differ from .tool-versions: {actual} != {expected}")
    return env


class RealMcpWorkflowTest(unittest.IsolatedAsyncioTestCase):
    async def test_online_warmup_and_offline_platform_workflow(self):
        env = tool_environment()
        with tempfile.TemporaryDirectory(prefix="opsd real MCP qualification ") as directory:
            root = Path(directory)
            workspace, cwd = root / "workspace", root / "host cwd"
            workspace.mkdir()
            cwd.mkdir()
            write_workspace(workspace)
            shutil.rmtree(workspace / "modules")
            manifest = read_manifest(workspace / "valid.yaml")
            manifest["spec"]["compute_groups"][0]["config"]["kubernetes_version"] = "1.33.0-do.0"
            (workspace / "valid.yaml").write_text(json.dumps(manifest))
            provider = root / "provider-source"
            run("git", "init", "-q", str(provider))
            run("git", "-C", str(provider), "remote", "add", "origin", PIN["provider_repository"])
            run("git", "-C", str(provider), "fetch", "origin", PIN["provider_commit"])
            run("git", "-C", str(provider), "checkout", "--detach", "FETCH_HEAD")
            # A real, locally packaged Helm chart eliminates live chart-repository dependencies.
            chart = root / "chart"
            (chart / "templates").mkdir(parents=True)
            (chart / "crds").mkdir()
            (chart / "Chart.yaml").write_text("apiVersion: v2\nname: qualification\nversion: 1.2.3\n")
            (chart / "templates/configmap.yaml").write_text("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: mcp-qualified\ndata:\n  mode: local-fixture\n")
            (chart / "crds/application.yaml").write_text(json.dumps({
                "apiVersion": "apiextensions.k8s.io/v1", "kind": "CustomResourceDefinition",
                "metadata": {"name": "applications.argoproj.io"},
                "spec": {"group": "argoproj.io", "scope": "Namespaced", "names": {"plural": "applications", "kind": "Application"},
                         "versions": [{"name": "v1alpha1", "served": True, "storage": True,
                                       "schema": {"openAPIV3Schema": {"type": "object", "properties": {
                                           "spec": {"type": "object", "x-kubernetes-preserve-unknown-fields": True}}}}}]},
            }))
            project_crd = json.loads((chart / "crds/application.yaml").read_text())
            project_crd["metadata"]["name"] = "appprojects.argoproj.io"
            project_crd["spec"]["names"] = {"plural": "appprojects", "kind": "AppProject"}
            (chart / "crds/appproject.yaml").write_text(json.dumps(project_crd))
            run("helm", "package", str(chart), "--destination", str(root), env=env)
            archive = root / "qualification-1.2.3.tgz"
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            cache = workspace / ".opsd/cache/helm"
            cache.mkdir(parents=True)
            shutil.copyfile(archive, cache / f"{digest}.tgz")
            kube = root / "kubernetes-source"
            module = kube / "modules/bootstrap/argocd"
            module.mkdir(parents=True)
            (module / "module.yaml").write_text(json.dumps({
                "apiVersion": "opsd.io/modules/v1alpha1", "kind": "KubernetesModule",
                "metadata": {"id": "argocd", "name": "Argo CD qualification", "description": "Local Helm fixture"},
                "spec": {"layer": "bootstrap", "source": {"type": "helm", "repository": "https://example.invalid/charts",
                    "chart": "qualification", "version": "1.2.3", "digest": f"sha256:{digest}"},
                    "defaults": "defaults.yaml", "schema": "schema.yaml", "ownership": {"type": "official",
                    "repository": "opsd-io/modules-kubernetes"}, "supported_providers": ["digitalocean"],
                    "validation": {"mode": "strict"}},
            }))
            (module / "defaults.yaml").write_text("{}\n")
            (module / "schema.yaml").write_text("type: object\n")
            kube_commit = commit_repo(kube)
            env.update(OPSD_APP_ROOT=str(APP_ROOT), OPSD_WORKSPACE_ROOT=str(workspace),
                       OPSD_MODULES_DIGITALOCEAN_REPO=str(provider), OPSD_MODULES_DIGITALOCEAN_REF=PIN["provider_commit"],
                       OPSD_MODULES_KUBERNETES_REPO=str(kube), OPSD_MODULES_KUBERNETES_REF=kube_commit)
            transcript = []

            async def call(client, name, arguments, success=True):
                response = await client.call_tool(name, arguments)
                transcript.append({"tool": name, "arguments": arguments, "output": response.structured_content,
                                   "content": [block.model_dump(mode="json") for block in response.content]})
                self.assertEqual(not success, response.is_error, response.content)
                return response

            stderr_path = root / "server-stderr.log"
            try:
                async with asyncio.timeout(300):
                    with stderr_path.open("w") as stderr:
                        params = StdioServerParameters(command=str(APP_ROOT / "bin/opsd-mcp"), env=env, cwd=str(cwd))
                        async with Client(stdio_client(params, errlog=stderr), mode="2026-07-28", read_timeout_seconds=90) as client:
                            self.assertEqual(["2026-07-28"], (await client.session.discover()).supported_versions)
                            await call(client, "modules-sync", {"manifest_path": "valid.yaml"}, success=False)
                            self.assertFalse((workspace / "modules").exists())
                            await call(client, "modules-sync", {"manifest_path": "valid.yaml", "confirmed": True})
                            lock_path = workspace / "opsd.lock.yaml"
                            pinned = lock_path.read_bytes()
                            self.assertEqual(PIN["provider_commit"], read_manifest(lock_path)["provider_modules"]["commit"])
                            await call(client, "validate-manifest", {"manifest_path": "valid.yaml"})
                            await call(client, "render-manifest", {"manifest_path": "valid.yaml", "output_dir": "platform", "include_platform": True})
                            self.assertIn("mcp-qualified", (workspace / "platform/platform/helm/argocd.yaml").read_text())
                            await call(client, "validate-manifest", {"manifest_path": "valid.yaml", "platform": True, "offline": True}, success=False)
                            await call(client, "validate-manifest", {"manifest_path": "valid.yaml", "platform": True})
                            self.assertEqual(pinned, lock_path.read_bytes())
                        # Warm caches must suffice when outbound HTTP is unavailable.
                        env.update(HTTP_PROXY="http://127.0.0.1:1", HTTPS_PROXY="http://127.0.0.1:1",
                                   ALL_PROXY="http://127.0.0.1:1", NO_PROXY="")
                        params = StdioServerParameters(command=str(APP_ROOT / "bin/opsd-mcp"), env=env, cwd=str(cwd))
                        async with Client(stdio_client(params, errlog=stderr), mode="2026-07-28", read_timeout_seconds=90) as client:
                            await call(client, "validate-manifest", {"manifest_path": "valid.yaml", "platform": True, "offline": True})
                            self.assertEqual(pinned, lock_path.read_bytes())
                            await call(client, "export-exit-pack", {"rendered_dir": "platform", "output_path": "handoff.tar.gz"})
                            with tarfile.open(workspace / "handoff.tar.gz") as archive:
                                self.assertIn("exit-pack/main.tf", archive.getnames())
                self.assertEqual([], list(cwd.iterdir()))
            except BaseException:
                diagnostics = Path(os.environ.get("OPSD_MCP_DIAGNOSTICS", SOURCE_ROOT / ".tmp/mcp-diagnostics"))
                diagnostics.mkdir(parents=True, exist_ok=True)
                (diagnostics / "real-workflow.json").write_text(json.dumps(transcript, indent=2))
                shutil.copyfile(stderr_path, diagnostics / "real-server-stderr.log")
                for name in ("valid.yaml", "opsd.lock.yaml"):
                    if (workspace / name).is_file():
                        shutil.copyfile(workspace / name, diagnostics / name)
                raise


if __name__ == "__main__":
    unittest.main(verbosity=2)
