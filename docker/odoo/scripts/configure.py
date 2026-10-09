# Executed inside `odoo shell` (``env`` is provided). Idempotent.
import json
import os

ICP = env["ir.config_parameter"].sudo()
Module = env["ir.module.module"].sudo()


def installed(name):
    return bool(Module.search([("name", "=", name), ("state", "=", "installed")]))


# --- Base URL (Odoo sits behind the load balancer) -------------------------
base_url = os.environ.get("ODOO_BASE_URL")
if base_url:
    ICP.set_param("web.base.url", base_url)
    ICP.set_param("web.base.url.freeze", "True")

# --- Admin password: only on the very first initialisation -----------------
if os.environ.get("ODOO_FIRST_INIT") == "1" and os.environ.get("ODOO_ADMIN_PASSWORD"):
    env.ref("base.user_admin").sudo().password = os.environ["ODOO_ADMIN_PASSWORD"]
    print("Admin user password set from secret")

# --- Keycloak (OpenID Connect) ---------------------------------------------
kc_public = os.environ.get("KEYCLOAK_PUBLIC_URL", "").rstrip("/")
if kc_public and installed("auth_oidc"):
    kc_internal = os.environ.get("KEYCLOAK_INTERNAL_URL", kc_public).rstrip("/")
    realm = os.environ.get("KEYCLOAK_REALM", "odoo")
    oidc_public = f"{kc_public}/realms/{realm}/protocol/openid-connect"
    oidc_internal = f"{kc_internal}/realms/{realm}/protocol/openid-connect"
    vals = {
        "name": os.environ.get("OIDC_PROVIDER_NAME", "Keycloak"),
        "flow": "id_token_code",
        "client_id": os.environ["OIDC_CLIENT_ID"],
        "client_secret": os.environ["OIDC_CLIENT_SECRET"],
        "enabled": True,
        "body": os.environ.get("OIDC_BUTTON_LABEL", "Log in with Keycloak"),
        "scope": "openid email profile",
        # Browser-facing endpoints must use the public URL, back-channel
        # calls stay inside the cluster.
        "auth_endpoint": f"{oidc_public}/auth",
        "end_session_endpoint": f"{oidc_public}/logout",
        "token_endpoint": f"{oidc_internal}/token",
        "jwks_uri": f"{oidc_internal}/certs",
        "validation_endpoint": f"{oidc_internal}/userinfo",
        "token_map": "sub:user_id",
    }
    Provider = env["auth.oauth.provider"].sudo()
    provider = Provider.search([("client_id", "=", vals["client_id"])], limit=1)
    if provider:
        provider.write(vals)
        print("Keycloak OIDC provider updated")
    else:
        Provider.create(vals)
        print("Keycloak OIDC provider created")
    ICP.set_param("auth_signup.invitation_scope", os.environ.get("OIDC_SIGNUP_SCOPE", "b2b"))

# --- MinIO attachment storage (fs_attachment_s3) ---------------------------
if os.environ.get("MINIO_ENDPOINT") and installed("fs_attachment_s3"):
    vals = {
        "name": "MinIO attachments",
        "protocol": "s3",
        "directory_path": os.environ["MINIO_BUCKET"],
        # "$VAR" values are resolved from the container environment at runtime,
        # so credentials never land in the database.
        "eval_options_from_env": True,
        "options": json.dumps({
            "endpoint_url": "$MINIO_ENDPOINT",
            "key": "$MINIO_ACCESS_KEY",
            "secret": "$MINIO_SECRET_KEY",
            "client_kwargs": {"region_name": os.environ.get("MINIO_REGION", "us-east-1")},
        }),
        "use_as_default_for_attachments": True,
        "use_filename_obfuscation": True,
    }
    Storage = env["fs.storage"].sudo()
    storage = Storage.search([("code", "=", "minio")], limit=1)
    if storage:
        storage.write(vals)
        print("MinIO storage updated")
    else:
        Storage.create(dict(vals, code="minio"))
        print("MinIO storage created")
    env.registry.clear_cache()
    # Move anything still on the local filestore (e.g. files written while the
    # modules were installed in this Job's ephemeral volume) into MinIO.
    env["ir.attachment"].sudo().with_context(storage_location="minio").force_storage()
    print("Attachments migrated to MinIO")

env.cr.commit()
