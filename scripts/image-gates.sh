#!/usr/bin/env bash
set -euo pipefail
umask 077
archive="${1:?Provide the OCI or Docker archive}"
reports="${2:-.reports}"
mkdir -p "$reports"
export TRIVY_DISABLE_VEX_NOTICE=true

trivy image --input "$archive" --scanners vuln --format json --output "$reports/image-vulnerabilities.json"
trivy image --input "$archive" --format cyclonedx --output "$reports/sbom.cdx.json"
jq -e '.bomFormat == "CycloneDX" and (.components | length > 0)' "$reports/sbom.cdx.json" >/dev/null
jq -e '
  any(.Results[]?; .Class == "os-pkgs") and
  ([ .Results[]?.Vulnerabilities[]? |
    select(.Severity == "CRITICAL" or
      (.Severity == "HIGH" and ((.FixedVersion // "") | length > 0))) ]
  | length == 0)
' "$reports/image-vulnerabilities.json" >/dev/null
