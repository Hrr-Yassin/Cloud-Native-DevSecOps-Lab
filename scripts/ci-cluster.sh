#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]]
candidate="${1:?Provide the locally built candidate or verified image digest}"
fixture="${2:-compliant}"
mode="${3:-local}"
case "$fixture" in compliant|noncompliant) ;; *) exit 64;; esac
case "$mode" in
  local)
    [[ "$candidate" == .lab/candidate.tar && -s "$candidate" ]]
    ;;
  signed)
    scripts/verify-release.sh "$candidate" "$GITHUB_REPOSITORY"
    image="$candidate"
    ;;
  *)
    exit 64
    ;;
esac
root="$PWD"
mkdir -p .reports
rm -f -- .reports/cluster-teardown.log
state=$(mktemp -d)
pf=''
created=false
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$pf" ]]; then
    kill "$pf" 2>/dev/null || true
    wait "$pf" 2>/dev/null || true
  fi
  if [[ "$created" == true ]]; then
    if k3d cluster delete dslab-ci >/dev/null; then
      printf '%s\n' 'The disposable CI cluster was deleted.' > .reports/cluster-teardown.log || status=1
    else
      printf '%s\n' 'The disposable CI cluster could not be deleted.' >&2
      if (( status == 0 )); then status=1; fi
    fi
  fi
  rm -rf -- "$state" || status=1
  exit "$status"
}
trap cleanup EXIT

clusters=$(k3d cluster list --no-headers)
if awk '$1 == "dslab-ci" {found=1} END {exit !found}' <<< "$clusters"; then
  printf 'A cluster with the test name already exists.\n' >&2
  exit 1
fi
created=true
k3d cluster create dslab-ci --api-port 127.0.0.1:6550 --no-lb \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false \
  --image docker.io/rancher/k3s:v1.35.10-k3s1 --wait --timeout 180s \
  --volume "$root/infra/ansible/files/audit.yaml:/etc/rancher/k3s/audit.yaml@server:0" \
  --k3s-arg '--disable=servicelb@server:0' --k3s-arg '--secrets-encryption@server:0' \
  --k3s-arg '--kube-apiserver-arg=audit-policy-file=/etc/rancher/k3s/audit.yaml@server:0' \
  --k3s-arg '--kube-apiserver-arg=audit-log-path=/var/log/devsecops-audit.json@server:0'
export KUBECONFIG="$state/ci.kubeconfig"
k3d kubeconfig get dslab-ci > "$KUBECONFIG"
kubectl wait --for=condition=Ready node --all --timeout=120s
printf '%s\n' 'The disposable K3s node reached Ready.' > .reports/cluster-create.log

node=k3d-dslab-ci-server-0
if [[ "$mode" == local ]]; then
  # Import the same archive that was scanned and will be transferred to the publisher.
  k3d image import "$candidate" --cluster dslab-ci
  normal=docker.io/library/dslab-candidate:ci
  digest=$(docker exec "$node" k3s ctr --namespace k8s.io images ls | awk -v name="$normal" '$1 == name {print $3}')
  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]
  image="docker.io/library/dslab-candidate@$digest"
  docker exec "$node" k3s ctr --namespace k8s.io images tag "$normal" "$image" >/dev/null
fi
export LAB_TLS_DIR="$state/tls"
scripts/deploy-desk.sh "$image"
scripts/check-controls.sh "$image" "$fixture"
docker exec "$node" k3s secrets-encrypt status | grep -F 'Encryption Status: Enabled' > .reports/encryption.log
docker exec "$node" cat /var/log/devsecops-audit.json | jq -es 'any(.[];
  .verb == "create" and .objectRef.namespace == "security-desk"
  and .objectRef.resource == "pods"
  and ((.requestURI // "") | contains("dryRun=All"))
  and (.responseStatus.code == 400 or .responseStatus.code == 403 or .responseStatus.code == 422)
  and ((.annotations["validation.policy.admission.k8s.io/validation_failure"] // "")
    | fromjson? | any(.[];
        .policy == "desk-pod-controls.lab.dev"
        and .binding == "desk-pod-controls"
        and (.message | contains("require a read-only container root filesystem")))))' >/dev/null
printf '%s\n' 'The K3s audit policy recorded the admission denial.' > .reports/audit.log

op=$(openssl rand -hex 24)
viewer=$(openssl rand -hex 24)
printf '%s\n' "$op" | kubectl exec -i -n security-desk deploy/desk -- node app/cli.mjs user fixture-operator admin
printf '%s\n' "$viewer" | kubectl exec -i -n security-desk deploy/desk -- node app/cli.mjs user fixture-viewer viewer
printf '{"operator":"%s","viewer":"%s"}\n' "$op" "$viewer" > "$state/accounts.json"
unset op viewer

kubectl -n kube-system port-forward --address 127.0.0.1 service/traefik 8443:443 > "$state/forward.log" 2>&1 &
pf=$!
https_ready=false
for attempt in {1..20}; do
  if curl --silent --fail --noproxy '*' --max-time 3 --cacert "$LAB_TLS_DIR/ca.crt" \
    --resolve desk.lab.invalid:8443:127.0.0.1 https://desk.lab.invalid:8443/healthz >/dev/null; then
    https_ready=true
    break
  fi
  kill -0 "$pf"
  sleep 2
done
[[ "$https_ready" == true ]] || { printf '%s\n' 'The TLS listener did not become ready.' >&2; exit 1; }
python3 scripts/http-acceptance.py --ca "$LAB_TLS_DIR/ca.crt" --fixture-credentials "$state/accounts.json" > .reports/https-acceptance.json
node scripts/browser-acceptance.mjs --ca "$LAB_TLS_DIR/ca.crt" \
  --fixture-credentials "$state/accounts.json" --report-dir .reports/browser
age-keygen -o "$state/backup-identity" > "$state/age-keygen.log" 2>&1
age-keygen -y "$state/backup-identity" > "$state/backup-recipients"
scripts/backup.sh export "$state/backup-recipients" "$state/desk-backup.age" > "$state/backup.ndjson"
TMPDIR="$state" scripts/backup.sh restore-check "$state/backup-identity" "$state/desk-backup.age" >> "$state/backup.ndjson"
jq -ces 'map({event, findings}) | if . == [
  {event: "backup_completed", findings: 1}, {event: "backup_verified", findings: 1}
] then .[] else error("Unexpected encrypted backup or restore-check results") end' \
  "$state/backup.ndjson" > "$state/verified-backup.log"
mv -- "$state/verified-backup.log" .reports/backup.log
kubectl rollout restart -n security-desk deployment/desk
kubectl rollout status -n security-desk deployment/desk --timeout=120s
python3 scripts/http-acceptance.py --ca "$LAB_TLS_DIR/ca.crt" --fixture-credentials "$state/accounts.json" --read-only > .reports/restart-acceptance.json
