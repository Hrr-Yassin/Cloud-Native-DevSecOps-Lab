#!/usr/bin/env bash
set -euo pipefail
image="${1:?Provide the GHCR image by immutable digest}"
repository="${2:?Provide the GitHub owner/repository}"
[[ "$repository" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]
[[ "$image" == "ghcr.io/${repository,,}@sha256:"* && "$image" =~ @sha256:[a-f0-9]{64}$ ]]
identity="https://github.com/$repository/.github/workflows/security.yml@refs/heads/main"
issuer=https://token.actions.githubusercontent.com
cosign verify --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" "$image" >/dev/null
cosign verify-attestation --type cyclonedx --certificate-identity "$identity" \
  --certificate-oidc-issuer "$issuer" "$image" >/dev/null
