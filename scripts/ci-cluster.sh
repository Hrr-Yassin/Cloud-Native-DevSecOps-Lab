#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]]
candidate="${1:?Provide the locally built candidate or verified image digest}"
fixture="${2:-compliant}"
mode="${3:-local}"
case "$mode" in local|signed) ;; *) exit 64;; esac
root="$PWD"
mkdir -p .reports
state=$(mktemp -d)
pf=''
created=false
cleanup() {
  if [[ -n "$pf" ]]; then kill "$pf" 2>/dev/null || true; fi
  if [[ "$created" == true ]]; then
    if k3d cluster delete dslab-ci >/dev/null; then
      printf '%s\n' 'The disposable CI cluster was deleted.' > .reports/cluster-teardown.log
    else
      rm -rf -- "$state"
      return 1
    fi
  fi
  rm -rf -- "$state"
}
trap cleanup EXIT

if k3d cluster list --no-headers | awk '$1 == "dslab-ci" {found=1} END {exit !found}'; then
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
  [[ "$candidate" == dslab-candidate:ci ]]
  k3d image import "$candidate" --cluster dslab-ci
  normal=docker.io/library/dslab-candidate:ci
  digest=$(docker exec "$node" k3s ctr --namespace k8s.io images ls | awk -v name="$normal" '$1 == name {print $3}')
  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]
  image="docker.io/library/dslab-candidate@$digest"
  docker exec "$node" k3s ctr --namespace k8s.io images tag "$normal" "$image" >/dev/null
else
  scripts/verify-release.sh "$candidate" "$GITHUB_REPOSITORY"
  image="$candidate"
fi
export LAB_TLS_DIR="$state/tls"
scripts/deploy-desk.sh "$image"
scripts/check-controls.sh "$image" "$fixture"
docker exec "$node" k3s secrets-encrypt status | grep -F 'Encryption Status: Enabled' > .reports/encryption.log
docker exec "$node" grep -Fq 'desk-pod-controls' /var/log/devsecops-audit.json
printf '%s\n' 'The K3s audit policy recorded the admission denial.' > .reports/audit.log

op=$(openssl rand -hex 24)
viewer=$(openssl rand -hex 24)
printf '%s\n' "$op" | kubectl exec -i -n security-desk deploy/desk -- node app/cli.mjs user fixture-operator admin
printf '%s\n' "$viewer" | kubectl exec -i -n security-desk deploy/desk -- node app/cli.mjs user fixture-viewer viewer
printf '{"operator":"%s","viewer":"%s"}\n' "$op" "$viewer" > "$state/accounts.json"
unset op viewer

kubectl -n kube-system port-forward --address 127.0.0.1 service/traefik 8443:443 > "$state/forward.log" 2>&1 &
pf=$!
for attempt in {1..20}; do
  if curl --silent --fail --noproxy '*' --max-time 3 --cacert "$LAB_TLS_DIR/ca.crt" \
    --resolve desk.lab.invalid:8443:127.0.0.1 https://desk.lab.invalid:8443/healthz >/dev/null; then
    break
  fi
  kill -0 "$pf"
  sleep 2
done
python3 scripts/http-acceptance.py --ca "$LAB_TLS_DIR/ca.crt" --fixture-credentials "$state/accounts.json" > .reports/https-acceptance.json
kubectl exec -n security-desk deploy/desk -- node app/cli.mjs backup /tmp/dslab-backup.sqlite > .reports/backup.log
kubectl exec -n security-desk deploy/desk -- node app/cli.mjs inspect /tmp/dslab-backup.sqlite >> .reports/backup.log
grep -Fq '"findings":1' .reports/backup.log
kubectl rollout restart -n security-desk deployment/desk
kubectl rollout status -n security-desk deployment/desk --timeout=120s
python3 scripts/http-acceptance.py --ca "$LAB_TLS_DIR/ca.crt" --fixture-credentials "$state/accounts.json" --read-only > .reports/restart-acceptance.json
