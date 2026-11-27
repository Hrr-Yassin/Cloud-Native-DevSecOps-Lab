#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
mkdir -p .reports
config="$PWD/security/gitleaks.toml"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

gitleaks git --log-opts=--all --config="$config" --redact=100 --no-banner \
  --report-format json --report-path .reports/gitleaks.json

# Generate the positive fixture only inside the isolated temporary source tree.
printf 'LAB_%s=lab_%s_%s\n' TEST_TOKEN fixture abcdefghijklmnopqrstuvwx > "$fixture/sample.env"
status=0
gitleaks dir "$fixture" --config="$config" --redact=100 --no-banner --exit-code=23 \
  --report-format json --report-path "$fixture/result.json" || status=$?
[[ "$status" == 23 ]]
jq -e 'any(.[]; .RuleID == "lab-fixture-marker")' "$fixture/result.json" >/dev/null
printf 'LAB_TEST_MARKER=synthetic\n' > "$fixture/sample.env"
rm -- "$fixture/result.json"
gitleaks dir "$fixture" --config="$config" --redact=100 --no-banner
printf '%s\n' '{"synthetic_marker":"rejected","corrected_marker":"accepted"}' > .reports/secret-fixture.json
