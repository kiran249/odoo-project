#!/usr/bin/env bash
# Install/upgrade the cluster-wide monitoring stack:
#   kube-prometheus-stack (Prometheus, Alertmanager, Grafana, exporters)
#   prometheus-blackbox-exporter (HTTP health probes for Odoo/Keycloak)
#
# Env: MONITORING_NAMESPACE (default monitoring)
#      GRAFANA_SSO_NAMESPACE (default odoo-prod): namespace whose Keycloak
#        Grafana logs in with; its grafana-oidc-client-secret is copied.
#      KPS_CHART_VERSION / BLACKBOX_CHART_VERSION: pin chart versions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${MONITORING_NAMESPACE:-monitoring}"
SSO_NS="${GRAFANA_SSO_NAMESPACE:-odoo-prod}"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Grafana admin credentials: generated once, then kept.
if ! kubectl -n "$NS" get secret grafana-admin >/dev/null 2>&1; then
  kubectl -n "$NS" create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="${GRAFANA_ADMIN_PASSWORD:-$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)}"
fi

# Grafana <-> Keycloak client secret
sso_args=()
client_secret="$(kubectl -n "$SSO_NS" get secret odoo-platform-secrets \
  -o jsonpath='{.data.grafana-oidc-client-secret}' 2>/dev/null | base64 -d || true)"
if [ -n "$client_secret" ]; then
  kubectl -n "$NS" create secret generic grafana-oidc \
    --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET="$client_secret" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
else
  echo "WARNING: no secret in namespace ${SSO_NS} yet; Grafana Keycloak login disabled for now."
  kubectl -n "$NS" create secret generic grafana-oidc \
    --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=unset \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  sso_args+=(--set 'grafana.grafana\.ini.auth\.generic_oauth.enabled=false')
fi

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "$NS" \
  ${KPS_CHART_VERSION:+--version "$KPS_CHART_VERSION"} \
  -f "$ROOT/monitoring/kube-prometheus-stack-values.yaml" \
  "${sso_args[@]}" \
  --wait --timeout 15m

helm upgrade --install prometheus-blackbox-exporter prometheus-community/prometheus-blackbox-exporter \
  --namespace "$NS" \
  ${BLACKBOX_CHART_VERSION:+--version "$BLACKBOX_CHART_VERSION"} \
  -f "$ROOT/monitoring/blackbox-exporter-values.yaml" \
  --wait --timeout 10m

echo "Monitoring stack is up to date in namespace ${NS}."
