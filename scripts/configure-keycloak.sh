#!/usr/bin/env bash
# ACCESS_MODE=address only: allow plain HTTP in Keycloak and point the Odoo
# and Grafana clients at the current addresses.
#
# The realm file is imported only on Keycloak's first start, so this runs on
# every deploy to keep the redirect URIs right if an address changes. Runs
# kcadm inside the Keycloak pod (over localhost, which is allowed before
# sslRequired is relaxed).
#
# Usage: scripts/configure-keycloak.sh <namespace> <odoo-url> [grafana-url]
# Env:   KEYCLOAK_REALM (default odoo), ODOO_CLIENT_ID (default odoo)
set -euo pipefail

NAMESPACE="${1:?usage: $0 <namespace> <odoo-url> [grafana-url]}"
ODOO_URL="${2:?odoo url required}"
GRAFANA_URL="${3:-}"
REALM="${KEYCLOAK_REALM:-odoo}"
ODOO_CLIENT_ID="${ODOO_CLIENT_ID:-odoo}"

kubectl -n "$NAMESPACE" exec -i deploy/keycloak -c keycloak -- bash -s -- \
  "$REALM" "$ODOO_CLIENT_ID" "$ODOO_URL" "$GRAFANA_URL" <<'EOF'
set -euo pipefail
realm="$1"; odoo_client="$2"; odoo_url="$3"; grafana_url="$4"
kcadm() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config; }

kcadm config credentials --server http://localhost:8080 --realm master \
  --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null

kcadm update realms/master -s sslRequired=NONE
kcadm update "realms/$realm" -s sslRequired=NONE

# update_client <clientId> <url> <redirect path>
update_client() {
  local id
  id="$(kcadm get clients -r "$realm" -q "clientId=$1" --fields id --format csv --noquotes)"
  [ -n "$id" ] || { echo "Client $1 not found in realm $realm"; return 1; }
  kcadm update "clients/$id" -r "$realm" \
    -s "rootUrl=$2" \
    -s "redirectUris=[\"$2$3\"]" \
    -s "webOrigins=[\"$2\"]" \
    -s "attributes.\"post.logout.redirect.uris\"=$2/*"
  echo "Keycloak client $1 -> $2"
}

update_client "$odoo_client" "$odoo_url" /auth_oauth/signin
[ -n "$grafana_url" ] && update_client grafana "$grafana_url" /login/generic_oauth
echo "Keycloak: plain HTTP allowed in realms master and $realm"
EOF
