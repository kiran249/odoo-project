# Odoo 18 image with the OCA modules this platform relies on:
#   - auth_oidc      (OCA/server-auth): login through Keycloak (OpenID Connect)
#   - fs_attachment* (OCA/storage):     store attachments/filestore in MinIO (S3)
# Custom addons from ./addons are copied in as well.
ARG ODOO_BASE_IMAGE=public.ecr.aws/docker/library/odoo:18.0
FROM ${ODOO_BASE_IMAGE}

# Pin OCA repositories to a commit for reproducible builds (bump deliberately).
ARG OCA_OIDC_REPO_REF=2d4f6d8fea71c936c4d3140b4fe226a858ee90a4
ARG OCA_STORAGE_REPO_REF=fb81a6083c6d84d48578ae9490c27f8139290d6e

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

COPY docker/odoo/requirements.txt /tmp/requirements.txt
RUN pip3 install --no-cache-dir --break-system-packages -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt

# fetch_oca <repo> <ref> <dest> <module...>: keeps only the listed modules
RUN set -eux; \
    fetch_oca() { \
        repo="$1"; ref="$2"; dest="$3"; shift 3; \
        tmp="$(mktemp -d)"; \
        git -C "$tmp" init -q; \
        git -C "$tmp" remote add origin "https://github.com/OCA/${repo}.git"; \
        git -C "$tmp" fetch -q --depth 1 origin "$ref"; \
        git -C "$tmp" checkout -q FETCH_HEAD; \
        mkdir -p "$dest"; \
        for m in "$@"; do cp -r "$tmp/$m" "$dest/"; done; \
        rm -rf "$tmp"; \
    }; \
    fetch_oca server-auth "$OCA_OIDC_REPO_REF" /mnt/oca-addons auth_oidc; \
    fetch_oca storage "$OCA_STORAGE_REPO_REF" /mnt/oca-addons fs_storage fs_attachment fs_attachment_s3; \
    apt-get purge -y git && apt-get autoremove -y

COPY --chown=odoo:odoo addons/ /mnt/extra-addons/
COPY --chown=odoo:odoo docker/odoo/scripts/ /usr/local/bin/odoo-platform/
RUN chmod +x /usr/local/bin/odoo-platform/*.sh

USER odoo
