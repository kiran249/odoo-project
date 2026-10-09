#!/usr/bin/env bash
# Create/update the platform secret in a namespace.
#
# For each key: use the matching environment variable if set (e.g. from a
# Jenkins credential), otherwise keep the value already in the cluster,
# otherwise generate a random one. Re-running never rotates existing values.
#
# Usage: scripts/create-secrets.sh <namespace>
set -euo pipefail

NAMESPACE="${1:?usage: $0 <namespace>}"
SECRET_NAME="${SECRET_NAME:-odoo-platform-secrets}"

# key=ENV_VAR
KEYS=(
  "postgres-password=POSTGRES_PASSWORD"
  "odoo-db-password=ODOO_DB_PASSWORD"
  "keycloak-db-password=KEYCLOAK_DB_PASSWORD"
  "minio-root-user=MINIO_ROOT_USER"
  "minio-root-password=MINIO_ROOT_PASSWORD"
  "odoo-admin-password=ODOO_ADMIN_PASSWORD"
  "keycloak-admin-password=KEYCLOAK_ADMIN_PASSWORD"
  "odoo-oidc-client-secret=ODOO_OIDC_CLIENT_SECRET"
  "grafana-oidc-client-secret=GRAFANA_OIDC_CLIENT_SECRET"
)

random_value() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}"; }

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

existing="$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o json 2>/dev/null || echo '{}')"

args=()
for entry in "${KEYS[@]}"; do
  key="${entry%%=*}"
  var="${entry#*=}"
  value="${!var:-}"
  source="env"
  if [ -z "$value" ]; then
    value="$(jq -r --arg k "$key" '.data[$k] // empty' <<<"$existing" | base64 -d)"
    source="existing"
  fi
  if [ -z "$value" ]; then
    if [ "$key" = "minio-root-user" ]; then value="odoo-$(random_value 8)"; else value="$(random_value 32)"; fi
    source="generated"
  fi
  echo "  ${key}: ${source}"
  args+=("--from-literal=${key}=${value}")
done

kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" "${args[@]}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "Secret ${NAMESPACE}/${SECRET_NAME} is up to date."
