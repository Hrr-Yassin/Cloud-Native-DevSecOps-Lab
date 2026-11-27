#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
source scripts/verify-target.sh
require_lab_context
[[ "$(kubectl config current-context)" == devsecops-lab ]]
ns=lab-observability
cfg=deploy/observability
mkdir -p .lab/helm
export HELM_REPOSITORY_CONFIG="$PWD/.lab/helm/repositories.yaml"
export HELM_REPOSITORY_CACHE="$PWD/.lab/helm/cache"
export HELM_REGISTRY_CONFIG="$PWD/.lab/helm/registry.json"
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add falcosecurity https://falcosecurity.github.io/charts
kubectl apply -f "$cfg/namespaces.yaml"
if [[ -z "$(kubectl -n "$ns" get secret lab-grafana-admin --ignore-not-found -o name)" ]]; then
  openssl rand -hex 24 | tr -d '\n' |
    kubectl -n "$ns" create secret generic lab-grafana-admin --from-literal=admin-user=admin --from-file=admin-password=/dev/stdin
fi
helm upgrade --install monitor oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
  --version 93.11.1 --namespace "$ns" --values "$cfg/monitor-values.yaml" --wait --timeout 8m
helm upgrade --install lab-logs grafana/loki --version 7.7.0 \
  --namespace "$ns" --values "$cfg/loki-values.yaml" --wait --timeout 6m
helm upgrade --install lab-collector grafana/alloy --version 1.12.1 --namespace "$ns" \
  --values "$cfg/alloy-values.yaml" --set-file alloy.configMap.content="$cfg/logs.alloy" --wait --timeout 5m
helm upgrade --install lab-ci oci://ghcr.io/prometheus-community/charts/prometheus-pushgateway \
  --version 3.9.0 --namespace "$ns" --set fullnameOverride=lab-ci --set service.type=ClusterIP --set service.portName=http --wait --timeout 4m
helm upgrade --install falco falcosecurity/falco --version 9.2.2 --namespace lab-runtime \
  --values "$cfg/falco-values.yaml" --wait --timeout 6m
kubectl apply -f "$cfg/telemetry.yaml"
kubectl -n "$ns" create configmap lab-security-dashboard --from-file=lab.json="$cfg/dashboard.json" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$ns" label configmap lab-security-dashboard grafana_dashboard=1 --overwrite
