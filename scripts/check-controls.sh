#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/verify-target.sh
require_lab_context
image="${1:?An immutable image already deployed to this context is required}"
fixture="${2:-compliant}"
case "$fixture" in compliant|noncompliant) ;; *) exit 64;; esac
[[ "$image" =~ ^[a-z0-9][a-z0-9./:-]+@sha256:[a-f0-9]{64}$ ]]
work=$(mktemp -d)
ns=lab-network-check
owned=false
cleanup() {
  if [[ "$owned" == true ]]; then kubectl delete namespace "$ns" --wait=false >/dev/null; fi
  rm -rf -- "$work"
}
trap cleanup EXIT
mkdir -p .reports
report=.reports/kubernetes-controls.log
: > "$report"
record() { printf '%s\n' "$*" | tee -a "$report"; }

kubectl -n security-desk rollout status deployment/desk --timeout=120s
for file in compliant noncompliant; do
  sed "s|IMAGE_FOR_ACCEPTANCE|$image|g" "security/fixtures/$file.yaml" > "$work/$file.yaml"
done
kubectl create --dry-run=server -f "$work/compliant.yaml" >/dev/null
record 'Admission accepted the compliant fixture.'
if kubectl create --dry-run=server -f "$work/noncompliant.yaml" > "$work/deny" 2>&1; then
  printf 'The admission fixture unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq 'desk-pod-controls: require a read-only container root filesystem' "$work/deny"
record 'Admission denied the writable-root fixture.'
sed 's/allowPrivilegeEscalation: false/allowPrivilegeEscalation: true/' "$work/compliant.yaml" > "$work/pss.yaml"
if kubectl create --dry-run=server -f "$work/pss.yaml" > "$work/deny" 2>&1; then
  printf 'The Pod Security fixture unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq 'violates PodSecurity' "$work/deny"
record 'Restricted Pod Security denied the privilege-escalation fixture.'

desk=system:serviceaccount:security-desk:desk
observer=system:serviceaccount:security-desk:desk-observer
promoter=system:serviceaccount:security-desk:lab-promoter
[[ "$(kubectl auth can-i --as="$desk" list secrets -n security-desk || true)" == no ]]
[[ "$(kubectl auth can-i --as="$observer" get pods -n security-desk)" == yes ]]
[[ "$(kubectl auth can-i --as="$observer" create pods -n security-desk || true)" == no ]]
[[ "$(kubectl auth can-i --as="$promoter" patch deployment/desk -n security-desk)" == yes ]]
[[ "$(kubectl auth can-i --as="$promoter" patch deployment/traefik -n kube-system || true)" == no ]]
[[ "$(kubectl auth can-i --as="$promoter" get secrets -n security-desk || true)" == no ]]
record 'Workload, observer and promotion RBAC matched their expected permissions.'

kubectl exec -n security-desk deploy/desk -- node -e '
  const fs = require("node:fs");
  const assert = require("node:assert/strict");
  assert.equal(process.getuid(), 10001);
  const status = fs.readFileSync("/proc/self/status", "utf8");
  assert.match(status, /^CapEff:\s+0+$/m);
  assert.match(status, /^NoNewPrivs:\s+1$/m);
  assert.match(status, /^Seccomp:\s+2$/m);
  const root = fs.readFileSync("/proc/mounts", "utf8").split("\n")
    .map((entry) => entry.split(" ")).find((entry) => entry[1] === "/");
  assert.ok(root[3].split(",").includes("ro"));
  assert.throws(() => fs.writeFileSync("/var/tmp/.desk-root-check", ""), { code: "EROFS" });
  assert.equal(fs.existsSync("/var/run/secrets/kubernetes.io/serviceaccount/token"), false);
'
record 'Container uses UID 10001, a read-only root, zero effective capabilities, seccomp and no API token.'

kubectl create -f - >/dev/null <<'NAMESPACE'
apiVersion: v1
kind: Namespace
metadata:
  name: lab-network-check
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.35
NAMESPACE
owned=true
sed "s|IMAGE_FOR_ACCEPTANCE|$image|g" security/fixtures/network-probe.yaml | kubectl create -f - >/dev/null
kubectl wait -n "$ns" --for=jsonpath='{.status.phase}'=Succeeded pod/desk-isolation --timeout=90s
record 'A separate namespace resolved both application services and timed out when connecting.'
kubectl create --dry-run=server -f "$work/$fixture.yaml"
record "The selected $fixture fixture passed its pipeline gate."
