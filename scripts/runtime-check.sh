#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/verify-target.sh
require_lab_context
[[ "$(kubectl config current-context)" == devsecops-lab ]]
mkdir -p .reports
work=$(mktemp -d)
pf=''
cleanup() {
  if [[ -n "$pf" ]]; then kill "$pf" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT
kubectl -n lab-runtime rollout status daemonset/falco --timeout=90s
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
kubectl exec -n security-desk deploy/desk -- node -e '
  const fs = require("node:fs");
  const path = "/tmp/devsecops-lab-runtime-marker";
  fs.writeFileSync(path, "synthetic marker");
  fs.unlinkSync(path);
'
ready=false
for attempt in {1..20}; do
  if kubectl -n lab-runtime logs daemonset/falco -c falco --since-time="$started" |
     python3 scripts/export-soc-events.py --source falco > "$work/events.jsonl" &&
     jq -es 'any(.[]; .event == "runtime_fixture")' "$work/events.jsonl" >/dev/null; then
    jq -c 'select(.event == "runtime_fixture")' "$work/events.jsonl" > .reports/falco-fixture.jsonl
    ready=true
    break
  fi
  sleep 2
done
[[ "$ready" == true ]]
kubectl -n lab-observability port-forward --address 127.0.0.1 service/monitor-alertmanager 19093:9093 \
  > "$work/alertmanager-forward.log" 2>&1 &
pf=$!
for attempt in {1..35}; do
  if curl --silent --fail --noproxy '*' --max-time 2 http://127.0.0.1:19093/api/v2/alerts |
     jq -e 'any(.[]; .labels.alertname == "LabRuntimeAlertObserved" and .status.state == "active")' >/dev/null; then
    printf '%s\n' 'Alertmanager received the Falco runtime fixture alert.' > .reports/runtime-alertmanager.log
    exit 0
  fi
  kill -0 "$pf"
  sleep 3
done
printf 'Alertmanager did not receive the controlled runtime alert in time.\n' >&2
exit 1
