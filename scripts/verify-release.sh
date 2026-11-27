#!/usr/bin/env bash
set -euo pipefail
image="${1:?Provide the GHCR image by immutable digest}"
repository="${2:?Provide the GitHub owner/repository}"
[[ "$repository" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]
prefix="ghcr.io/${repository,,}@sha256:"
digest="${image#"$prefix"}"
[[ "$image" == "$prefix"* && "$digest" =~ ^[a-f0-9]{64}$ ]] ||
  { printf '%s\n' 'Use the repository GHCR image with one SHA-256 digest.' >&2; exit 64; }
identity="https://github.com/$repository/.github/workflows/security.yml@refs/heads/main"
issuer=https://token.actions.githubusercontent.com
cosign verify --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" "$image" >/dev/null
cosign verify-attestation --type cyclonedx --certificate-identity "$identity" \
  --certificate-oidc-issuer "$issuer" "$image" >/dev/null
