#!/usr/bin/env bash

ensure_ghcr_pull_secret() {
  local namespace=$1 image=$2
  if [[ "$image" != ghcr.io/* || ! -r "${LAB_REGISTRY_AUTH_FILE:-}" ]]; then
    printf 'A private GHCR image and a readable registry auth file are required.\n' >&2
    return 64
  fi
  jq -ec '.auths["ghcr.io"] | select(.auth | type == "string" and length > 0) | {auths:{"ghcr.io":{auth:.auth}}}' \
    "$LAB_REGISTRY_AUTH_FILE" |
    kubectl -n "$namespace" create secret generic desk-registry-pull \
      --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin \
      --dry-run=client -o yaml | kubectl apply --server-side --field-manager=desk-bootstrap -f -
}
