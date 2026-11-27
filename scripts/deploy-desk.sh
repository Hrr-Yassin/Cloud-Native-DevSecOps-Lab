#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/verify-target.sh
require_lab_context
image="${1:?Provide the verified application image digest}"
expected='^[a-z0-9][a-z0-9./:-]+@sha256:[a-f0-9]{64}$'
[[ "$image" =~ $expected ]] || { printf 'An immutable image reference is required.\n' >&2; exit 64; }
directory="${LAB_TLS_DIR:-.lab/tls}"

scripts/issue-tls.sh "$directory"

kubectl apply -f deploy/base/namespace.yaml
kubectl apply -f deploy/policy/admission.yaml
kubectl apply -f deploy/base/access.yaml -f deploy/base/quota.yaml -f deploy/base/network.yaml
if [[ -n "${LAB_REGISTRY_AUTH_FILE:-}" ]]; then
  [[ "$image" == ghcr.io/* && -r "$LAB_REGISTRY_AUTH_FILE" ]]
  jq -ec '.auths["ghcr.io"] | select(.auth | type == "string" and length > 0) | {auths:{"ghcr.io":{auth:.auth}}}' \
    "$LAB_REGISTRY_AUTH_FILE" |
    kubectl -n security-desk create secret generic desk-registry-pull \
      --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin \
      --dry-run=client -o yaml | kubectl apply --server-side --field-manager=desk-bootstrap -f -
  kubectl -n security-desk patch serviceaccount desk --type=merge \
    -p '{"imagePullSecrets":[{"name":"desk-registry-pull"}]}'
fi
if [[ -z "$(kubectl -n security-desk get secret desk-session --ignore-not-found -o name)" ]]; then
  openssl rand 32 | kubectl -n security-desk create secret generic desk-session --from-file=session.key=/dev/stdin
fi
kubectl -n security-desk create secret tls desk-tls --cert="$directory/desk.crt" --key="$directory/desk.key"   --dry-run=client -o yaml | kubectl apply --server-side --field-manager=desk-bootstrap -f -
sed "s|IMAGE_FOR_ACCEPTANCE|$image|g" deploy/base/workload.yaml | kubectl apply -f -
kubectl apply -f deploy/base/ingress.yaml
kubectl -n kube-system wait --for=create deployment/traefik --timeout=240s
kubectl -n kube-system rollout status deployment/traefik --timeout=240s
kubectl -n security-desk rollout status deployment/desk --timeout=180s
