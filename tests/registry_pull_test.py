import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory
import unittest

ROOT = Path(__file__).resolve().parents[1]

KUBECTL_FIXTURE = r'''#!/usr/bin/env python3
import base64
import json
import os
from pathlib import Path
import sys

import yaml

args = sys.argv[1:]
namespace = "default"
if args[0] in ("-n", "--namespace"):
    namespace = args[1]
    args = args[2:]

def record(resource):
    with Path(os.environ["TEST_KUBECTL_LOG"]).open("a") as log:
        print(json.dumps(resource), file=log)

def manifest():
    name = args[args.index("-f") + 1]
    return yaml.safe_load(sys.stdin if name == "-" else Path(name).read_text())

def deny(message):
    print(message, file=sys.stderr)
    sys.exit(1)

if args[:2] == ["config", "current-context"]:
    print("k3d-dslab-ci")
elif args[:2] == ["config", "view"]:
    print("https://127.0.0.1:6550")
elif args[:2] == ["auth", "can-i"]:
    action = [arg for arg in args[2:] if not arg.startswith("--as=")][:2]
    print("yes" if action in (["get", "pods"], ["patch", "deployment/desk"]) else "no")
elif args[:3] == ["create", "secret", "generic"]:
    assert "--type=kubernetes.io/dockerconfigjson" in args
    assert "--from-file=.dockerconfigjson=/dev/stdin" in args
    print(json.dumps({"kind": "Secret", "metadata": {"name": args[3], "namespace": namespace},
                      "data": {".dockerconfigjson": base64.b64encode(sys.stdin.buffer.read()).decode()}}))
elif args[0] == "create":
    doc = manifest()
    if "--dry-run=server" not in args:
        record(doc)
    elif doc["kind"] == "PersistentVolumeClaim":
        deny("exceeded quota: desk-quota, requests.storage=3Gi")
    else:
        container = doc["spec"]["containers"][0]
        if container["securityContext"]["allowPrivilegeEscalation"]:
            deny("violates PodSecurity")
        if not container["securityContext"]["readOnlyRootFilesystem"]:
            deny("desk-pod-controls: require a read-only container root filesystem")
        if container["resources"]["limits"]["cpu"] == "1500m":
            deny("maximum cpu usage per Container is 1")
elif args[0] == "apply":
    record(manifest())
elif args[0] == "patch" and "--local" in args:
    real_kubectl = os.environ.get("TEST_OFFLINE_KUBECTL")
    if real_kubectl:
        os.execv(real_kubectl, [real_kubectl, "--kubeconfig=/dev/null", *args])
    doc = manifest()
    patch = json.loads(args[args.index("-p") + 1])
    doc["spec"].update(patch["spec"])
    print(json.dumps(doc))
elif args[:2] == ["get", "endpointslices"]:
    print('{"items":[{"endpoints":[{"conditions":{"ready":true}}]}]}')
elif args[0] not in ("rollout", "exec", "wait", "logs", "delete"):
    deny("Unexpected kubectl fixture command: " + args[0])
'''


class RegistryPullTest(unittest.TestCase):
    def run_controls(self, image, auth_config=None):
        with TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            scripts = workspace / "scripts"
            (scripts / "lib").mkdir(parents=True)
            for name in ("check-controls.sh", "verify-target.sh", "lib/registry-pull.sh"):
                shutil.copy(ROOT / "scripts" / name, scripts / name)
            (workspace / "security").symlink_to(ROOT / "security", target_is_directory=True)
            kubectl = workspace / "kubectl"
            kubectl.write_text(KUBECTL_FIXTURE)
            kubectl.chmod(0o700)
            log = workspace / "kubectl.jsonl"
            env = {**os.environ, "PATH": f"{workspace}:{os.environ['PATH']}", "TEST_KUBECTL_LOG": str(log)}
            env.pop("LAB_REGISTRY_AUTH_FILE", None)
            if auth_config is not None:
                config = workspace / "registry.json"
                config.write_text(json.dumps(auth_config))
                env["LAB_REGISTRY_AUTH_FILE"] = str(config)
            real_kubectl = shutil.which("kubectl") or ROOT / ".lab/bin/kubectl"
            if Path(real_kubectl).is_file():
                env["TEST_OFFLINE_KUBECTL"] = str(real_kubectl)
            result = subprocess.run([scripts / "check-controls.sh", image], cwd=workspace, env=env,
                                    text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            return [json.loads(line) for line in log.read_text().splitlines()]

    def test_private_probe_uses_ghcr_only_secret_in_its_namespace(self):
        auth = base64.b64encode(b"fixture-user:fixture-password").decode()
        image = "ghcr.io/example/desk@sha256:" + "a" * 64
        resources = self.run_controls(image, {"auths": {"ghcr.io": {"auth": auth},
                                                      "example.invalid": {"auth": auth}}})
        namespace, secret, pod = resources
        self.assertEqual([resource["kind"] for resource in resources], ["Namespace", "Secret", "Pod"])
        self.assertEqual(namespace["metadata"]["name"], "lab-network-check")
        self.assertEqual(secret["metadata"], {"name": "desk-registry-pull", "namespace": "lab-network-check"})
        self.assertEqual(json.loads(base64.b64decode(secret["data"][".dockerconfigjson"])),
                         {"auths": {"ghcr.io": {"auth": auth}}})
        self.assertEqual(pod["metadata"]["namespace"], "lab-network-check")
        self.assertEqual(pod["spec"]["imagePullSecrets"], [{"name": "desk-registry-pull"}])
        self.assertFalse(pod["spec"]["automountServiceAccountToken"])
        self.assertEqual(pod["spec"]["containers"][0]["image"], image)

    def test_preloaded_probe_uses_no_registry_credentials(self):
        image = "docker.io/library/dslab-candidate@sha256:" + "b" * 64
        resources = self.run_controls(image)
        self.assertEqual([resource["kind"] for resource in resources], ["Namespace", "Pod"])
        self.assertNotIn("imagePullSecrets", resources[-1]["spec"])
