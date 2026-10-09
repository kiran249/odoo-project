#!/usr/bin/env bash
# In-cluster health checks for every component of one environment.
# Usage: scripts/smoke-test.sh <namespace>
set -euo pipefail

NAMESPACE="${1:?usage: $0 <namespace>}"
pod="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/component=odoo \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"

check() {
  local name="$1" url="$2"
  if kubectl -n "$NAMESPACE" exec "$pod" -c odoo -- curl -fsS -o /dev/null --max-time 15 "$url"; then
    echo "OK    ${name}"
  else
    echo "FAIL  ${name} (${url})"
    failed=1
  fi
}

failed=0
check "Odoo health"            "http://localhost:8069/web/health"
check "Odoo login page"        "http://localhost:8069/web/login"
check "Keycloak realm (OIDC)"  "http://keycloak.${NAMESPACE}.svc.cluster.local:8080/realms/${KEYCLOAK_REALM:-odoo}/.well-known/openid-configuration"
check "MinIO"                  "http://minio.${NAMESPACE}.svc.cluster.local:9000/minio/health/live"

if kubectl -n "$NAMESPACE" exec "$pod" -c odoo -- curl -fsS --max-time 15 http://localhost:8069/web/login | grep -q "openid-connect/auth"; then
  echo "OK    Keycloak login button on Odoo"
else
  echo "WARN  Keycloak login button not found on /web/login"
fi

exit "$failed"
