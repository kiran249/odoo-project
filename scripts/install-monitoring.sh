#!/usr/bin/env bash
# Install/upgrade the cluster-wide monitoring stack:
#   kube-prometheus-stack (Prometheus, Alertmanager, Grafana, exporters)
#   prometheus-blackbox-exporter (HTTP health probes for Odoo/Keycloak)
#
# Env: MONITORING_NAMESPACE (default monitoring)
#      GRAFANA_SSO_NAMESPACE (default odoo-prod): namespace whose Keycloak
#        Grafana logs in with; its grafana-oidc-client-secret is copied.
#      KPS_CHART_VERSION / BLACKBOX_CHART_VERSION: pin chart versions.
#      ACCESS_MODE: address (default: Grafana on plain HTTP at its ALB address)
#        or domains (the hostname and certificate in the values file)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${MONITORING_NAMESPACE:-monitoring}"
SSO_NS="${GRAFANA_SSO_NAMESPACE:-odoo-prod}"
ACCESS_MODE="${ACCESS_MODE:-address}"

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
values_args=(-f "$ROOT/monitoring/kube-prometheus-stack-values.yaml")
client_secret="$(kubectl -n "$SSO_NS" get secret odoo-platform-secrets \
  -o jsonpath='{.data.grafana-oidc-client-secret}' 2>/dev/null | base64 -d || true)"
if [ -z "$client_secret" ]; then
  echo "WARNING: no secret in namespace ${SSO_NS} yet; Grafana Keycloak login disabled for now."
  values_args+=(--set 'grafana.grafana\.ini.auth\.generic_oauth.enabled=false')
fi
kubectl -n "$NS" create secret generic grafana-oidc \
  --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET="${client_secret:-unset}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Grafana's URL and the Keycloak endpoints it logs in with. Browser-facing
# URLs come from the ALB addresses (address mode) or from the domains overlay;
# token/userinfo calls stay inside the cluster.
oidc_internal="http://keycloak.${SSO_NS}.svc.cluster.local:8080/realms/odoo/protocol/openid-connect"
generated="$(mktemp)"
trap 'rm -f "$generated"' EXIT
grafana_url=""
if [ "$ACCESS_MODE" = "address" ]; then
  echo "Waiting for the load balancer address of ${NS}..."
  grafana_url="http://$("$ROOT/scripts/ensure-alb.sh" "$NS")"
  keycloak_url=""
  if [ -n "$client_secret" ]; then
    echo "Waiting for the load balancer address of ${SSO_NS}..."
    keycloak_url="http://$("$ROOT/scripts/ensure-alb.sh" "$SSO_NS"):8080"
  fi
  oidc="${keycloak_url}/realms/odoo/protocol/openid-connect"
  cat > "$generated" <<EOF
grafana:
  grafana.ini:
    server:
      root_url: ${grafana_url}
    auth.generic_oauth:
      auth_url: ${oidc}/auth
      token_url: ${oidc_internal}/token
      api_url: ${oidc_internal}/userinfo
      signout_redirect_url: ${oidc}/logout?post_logout_redirect_uri=${grafana_url}/login
EOF
else
  values_args+=(-f "$ROOT/monitoring/kube-prometheus-stack-values-domains.yaml")
  cat > "$generated" <<EOF
grafana:
  grafana.ini:
    auth.generic_oauth:
      token_url: ${oidc_internal}/token
      api_url: ${oidc_internal}/userinfo
EOF
fi
values_args+=(-f "$generated")

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "$NS" \
  ${KPS_CHART_VERSION:+--version "$KPS_CHART_VERSION"} \
  "${values_args[@]}" \
  --wait --timeout 15m

helm upgrade --install prometheus-blackbox-exporter prometheus-community/prometheus-blackbox-exporter \
  --namespace "$NS" \
  ${BLACKBOX_CHART_VERSION:+--version "$BLACKBOX_CHART_VERSION"} \
  -f "$ROOT/monitoring/blackbox-exporter-values.yaml" \
  --wait --timeout 10m

echo "Monitoring stack is up to date in namespace ${NS}."
if [ -n "$grafana_url" ]; then
  echo "Grafana: ${grafana_url}/  (user admin, password in secret ${NS}/grafana-admin)"
fi
