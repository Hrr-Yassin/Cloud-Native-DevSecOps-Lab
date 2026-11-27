#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ "${GITHUB_EVENT_NAME:-}:${GITHUB_REF:-}" == push:refs/heads/main ]]
registry="ghcr.io/${GITHUB_REPOSITORY,,}"
tag="$registry:$GITHUB_SHA"
identity="https://github.com/$GITHUB_REPOSITORY/.github/workflows/security.yml@refs/heads/main"
issuer=https://token.actions.githubusercontent.com
export DOCKER_CONFIG
DOCKER_CONFIG=$(mktemp -d)
trap 'rm -rf -- "$DOCKER_CONFIG"' EXIT
printf '%s' "$GHCR_TOKEN" | docker login ghcr.io --username "$GITHUB_ACTOR" --password-stdin
unset GHCR_TOKEN
docker image load --input artifacts/.lab/candidate.tar
docker image tag dslab-candidate:ci "$tag"
docker push "$tag"
image=$(docker image inspect "$tag" --format '{{json .RepoDigests}}' |
  jq -er --arg repo "$registry" '.[] | select(startswith($repo + "@"))')
[[ "$image" =~ @sha256:[a-f0-9]{64}$ ]]
cosign sign --yes "$image"
cosign attest --yes --type cyclonedx --predicate artifacts/.reports/sbom.cdx.json "$image"
cosign verify --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" "$image" >/dev/null
cosign verify-attestation --type cyclonedx --certificate-identity "$identity" \
  --certificate-oidc-issuer "$issuer" "$image" >/dev/null
mkdir -p release-evidence
jq --null-input --arg image "$image" --argjson run "$GITHUB_RUN_ID" \
  '{schema:1,run_id:$run,image:$image,signed:true,sbom_attested:true}' > release-evidence/release.json
printf 'Verified image `%s`\n' "$image" >> "$GITHUB_STEP_SUMMARY"
