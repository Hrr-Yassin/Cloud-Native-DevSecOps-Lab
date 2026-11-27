#!/usr/bin/env bash
set -euo pipefail

retry() {
  local attempts=$1 delay=$2 attempt
  shift 2
  for ((attempt = 1; attempt < attempts; attempt++)); do
    if "$@"; then return 0; fi
    sleep "$delay"
  done
  "$@"
}

fixture_records() {
  jq -Rc --arg marker "$1" '
    fromjson? | select(type == "object" and (.output_fields | type == "object")) |
    select(.rule == "DevSecOps Lab Runtime Marker" and .output_fields["fd.name"] == $marker)
  '
}

current_fixture_alert() {
  jq -e --argjson started "$1" '
    any(.[];
      .labels.alertname == "LabRuntimeFixtureObserved" and .status.state == "active"
      and (try (.startsAt | capture("^(?<seconds>[^.Z+]+)(?<fraction>[.][0-9]+)?(?:Z|[+]00:00)$")
        | ((.seconds + "Z" | fromdateiso8601) + ("0" + (.fraction // "") | tonumber)) * 1000
        | . >= $started) catch false))
  ' >/dev/null
}

forward_service() {
  local service=$1 remote_port=$2 result_variable=$3 port pid attempt
  local log="$work/$service.log"
  kubectl -n lab-observability port-forward --address 127.0.0.1 "service/$service" ":$remote_port" > "$log" 2>&1 &
  pid=$!
  forward_pids+=("$pid")
  for ((attempt = 0; attempt < 30; attempt++)); do
    port=$(sed -n 's/^Forwarding from 127[.]0[.]0[.]1:\([0-9][0-9]*\) -> .*/\1/p' "$log" | head -n 1)
    if [[ "$port" =~ ^[0-9]{1,5}$ ]]; then
      printf -v "$result_variable" '%s' "$port"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 1
  done
  printf 'Could not establish the %s port-forward.\n' "$service" >&2
  return 1
}

prometheus_query() {
  curl --silent --fail --noproxy '*' --max-time 3 --get \
    --data-urlencode "query=$1" "http://127.0.0.1:$prometheus_port/api/v1/query"
}

collector_up() {
  prometheus_query 'up{service="lab-collector",endpoint="http-metrics"} == 1' |
    jq -e '.status == "success" and (.data.result | length > 0)' >/dev/null
}

fixture_total() {
  prometheus_query 'sum(lab_runtime_fixture_total) or vector(0)' |
    jq -er 'select(.status == "success") | .data.result[0].value[1] | tonumber | select(. >= 0 and . == floor)'
}

metric_increased() {
  local current_total
  current_total=$(fixture_total) && (( current_total > baseline_total ))
}

falco_logged_fixture() {
  kubectl -n lab-runtime logs daemonset/falco -c falco --tail=500 |
    fixture_records "$marker" > "$work/fixture.jsonl" &&
    [[ -s "$work/fixture.jsonl" ]]
}

loki_logged_fixture() {
  curl --silent --fail --noproxy '*' --max-time 3 --get \
    --data-urlencode "query={source=\"falco\"} |= \"$marker\"" \
    --data-urlencode 'since=10m' --data-urlencode 'limit=10' \
    "http://127.0.0.1:$loki_port/loki/api/v1/query_range" |
    jq -r 'select(.status == "success") | .data.result[].values[][1]' |
    fixture_records "$marker" > "$work/loki-fixture.jsonl" &&
    [[ -s "$work/loki-fixture.jsonl" ]]
}

alertmanager_received_fixture() {
  curl --silent --fail --noproxy '*' --max-time 3 "http://127.0.0.1:$alertmanager_port/api/v2/alerts" |
    current_fixture_alert "$started"
}

cleanup() {
  if (( ${#forward_pids[@]} > 0 )); then
    kill "${forward_pids[@]}" 2>/dev/null || true
    wait "${forward_pids[@]}" 2>/dev/null || true
  fi
  rm -rf -- "$work"
}

main() {
  umask 077
  cd "$(dirname "$0")/.."
  source scripts/verify-target.sh
  require_lab_context
  [[ "$(kubectl config current-context)" == devsecops-lab ]]
  forward_pids=()
  work=$(mktemp -d)
  trap cleanup EXIT

  kubectl -n lab-runtime rollout status daemonset/falco --timeout=90s
  forward_service monitor-prometheus 9090 prometheus_port
  forward_service lab-logs 3100 loki_port
  forward_service monitor-alertmanager 9093 alertmanager_port
  retry 30 2 collector_up || { printf 'Prometheus could not scrape Alloy.\n' >&2; return 1; }
  baseline_total=$(fixture_total)
  marker="/tmp/devsecops-lab-runtime-marker-$(openssl rand -hex 8)"

  started=$(kubectl exec -n security-desk deploy/desk -- node -e '
    const fs = require("node:fs");
    const path = process.argv[1];
    const started = Date.now();
    fs.writeFileSync(path, "synthetic marker", { flag: "wx" });
    fs.unlinkSync(path);
    console.log(started);
  ' "$marker")
  [[ "$started" =~ ^[0-9]+$ ]]

  retry 20 2 falco_logged_fixture || { printf 'Falco did not record the marker from this run.\n' >&2; return 1; }
  retry 30 2 loki_logged_fixture || { printf 'Loki did not receive the marker from this run.\n' >&2; return 1; }
  retry 30 2 metric_increased || { printf 'Prometheus did not observe a fixture counter increment.\n' >&2; return 1; }
  retry 35 3 alertmanager_received_fixture ||
    { printf 'Alertmanager did not activate a new fixture alert. An earlier active fixture alert can overlap this run.\n' >&2; return 1; }

  mkdir -p .reports
  local report
  report=$(mktemp -d .reports/runtime-check.XXXXXXXX)
  python3 scripts/export-soc-events.py --source falco < "$work/fixture.jsonl" > "$report/falco-fixture.jsonl"
  printf '%s\n' 'Falco recorded the per-run marker and Loki received the event.' \
    'Prometheus observed the fixture counter increment and Alertmanager activated a current fixture alert.' \
    > "$report/runtime-alertmanager.log"
  printf 'Runtime acceptance passed. Sanitized evidence is in %s.\n' "$report"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
