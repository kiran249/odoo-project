#!/usr/bin/env bash
# Deploy/upgrade the odoo-platform chart for one environment.
#
# Usage: scripts/deploy-app.sh <env> <image-repository> <image-tag> [update-modules]
# Env:   MINIO_IMAGE (full image reference of the MinIO build in ECR)
set -euo pipefail

ENVIRONMENT="${1:?usage: $0 <env> <image-repository> <image-tag> [update-modules]}"
IMAGE_REPOSITORY="${2:?image repository required}"
IMAGE_TAG="${3:?image tag required}"
UPDATE_MODULES="${4:-}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAMESPACE="${NAMESPACE:-odoo-${ENVIRONMENT}}"
RELEASE="${RELEASE:-odoo-platform}"

helm upgrade --install "$RELEASE" "$ROOT/helm/odoo-platform" \
  --namespace "$NAMESPACE" \
  -f "$ROOT/environments/${ENVIRONMENT}/values.yaml" \
  --set-string odoo.image.repository="$IMAGE_REPOSITORY" \
  --set-string odoo.image.tag="$IMAGE_TAG" \
  --set-string odoo.init.updateModules="$UPDATE_MODULES" \
  ${MINIO_IMAGE:+--set-string minio.image="$MINIO_IMAGE"} \
  --wait --timeout 30m

kubectl -n "$NAMESPACE" rollout status deployment/odoo --timeout=10m
kubectl -n "$NAMESPACE" rollout status deployment/keycloak --timeout=10m 2>/dev/null || true
