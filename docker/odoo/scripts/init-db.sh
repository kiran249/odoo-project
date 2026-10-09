#!/bin/bash
# Initialise (first run) or upgrade the Odoo database, then apply platform
# settings (Keycloak login, MinIO attachment storage, base URL).
# Runs as a Kubernetes Job on every deploy; safe to run repeatedly.
#
# Required env: ODOO_RC, ODOO_DB_NAME, PGHOST, PGPORT, PGUSER, PGPASSWORD
# Optional env: ODOO_INSTALL_MODULES, ODOO_UPDATE_MODULES (comma-separated)
set -euo pipefail

: "${ODOO_RC:?}" "${ODOO_DB_NAME:?}" "${PGHOST:?}" "${PGUSER:?}" "${PGPASSWORD:?}"
export PGPORT="${PGPORT:-5432}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Waiting for PostgreSQL at ${PGHOST}:${PGPORT}..."
for _ in $(seq 1 60); do
    pg_isready -q -d postgres && break
    sleep 5
done
pg_isready -d postgres

# odoo_cmd <args...>: run Odoo once against the platform database, no HTTP.
# Database credentials come from the PG* environment (read by libpq).
odoo_cmd() {
    odoo -c "$ODOO_RC" -d "$ODOO_DB_NAME" --no-http "$@"
}

if [ -n "${MINIO_ENDPOINT:-}" ]; then
    python3 "$SCRIPT_DIR/create-bucket.py"
fi

initialised="$(psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '${ODOO_DB_NAME}'")"
if [ "$initialised" = "1" ]; then
    initialised="$(psql -d "$ODOO_DB_NAME" -tAc "SELECT to_regclass('public.ir_module_module') IS NOT NULL")"
fi

if [ "$initialised" != "t" ]; then
    echo "Database '${ODOO_DB_NAME}' is not initialised: installing ${ODOO_INSTALL_MODULES:-base}"
    odoo_cmd -i "${ODOO_INSTALL_MODULES:-base}" --without-demo=all --stop-after-init
    export ODOO_FIRST_INIT=1
else
    missing=""
    IFS=',' read -ra wanted <<< "${ODOO_INSTALL_MODULES:-}"
    for module in "${wanted[@]}"; do
        module="$(echo "$module" | xargs)"
        [ -z "$module" ] && continue
        state="$(psql -d "$ODOO_DB_NAME" -tAc "SELECT state FROM ir_module_module WHERE name = '${module}'")"
        [ "$state" != "installed" ] && missing="${missing:+$missing,}$module"
    done

    args=()
    [ -n "$missing" ] && args+=(-i "$missing")
    [ -n "${ODOO_UPDATE_MODULES:-}" ] && args+=(-u "$ODOO_UPDATE_MODULES")
    if [ ${#args[@]} -gt 0 ]; then
        echo "Running Odoo with: ${args[*]}"
        odoo_cmd "${args[@]}" --stop-after-init
    else
        echo "No modules to install or upgrade."
    fi
fi

echo "Applying platform configuration..."
odoo shell -c "$ODOO_RC" -d "$ODOO_DB_NAME" --no-http < "$SCRIPT_DIR/configure.py"
echo "Done."
