#!/usr/bin/env bash
set -euo pipefail
umask 077
source="${1:?Provide an OCI layout directory or Docker archive}"
reports="${2:-.reports}"
mkdir -p "$reports"
export TRIVY_DISABLE_VEX_NOTICE=true

trivy image --input "$source" --no-progress --scanners vuln --format json --output "$reports/image-vulnerabilities.json"
trivy image --input "$source" --no-progress --format cyclonedx --output "$reports/sbom.cdx.json"
jq -e '.bomFormat == "CycloneDX" and (.components | length > 0)' "$reports/sbom.cdx.json" >/dev/null
jq -e '
  any(.Results[]?; .Class == "os-pkgs") and
  ([ .Results[]?.Vulnerabilities[]? |
    select(.Severity == "CRITICAL" or
      (.Severity == "HIGH" and ((.FixedVersion // "") | length > 0))) ]
  | length == 0)
' "$reports/image-vulnerabilities.json" >/dev/null
