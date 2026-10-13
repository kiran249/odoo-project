#!/usr/bin/env bash
# Deploy/upgrade the odoo-platform chart for one environment.
#
# Usage: scripts/deploy-app.sh <env> <image-repository> <image-tag> [update-modules]
# Env:   MINIO_IMAGE (full image reference of the MinIO build in ECR)
#        ACCESS_MODE address (default: plain HTTP on the ALB address) or
#                    domains (HTTPS on the hostnames in environments/<env>/values.yaml)
#        MONITORING_NAMESPACE (default monitoring): where Grafana's ALB lives
set -euo pipefail

ENVIRONMENT="${1:?usage: $0 <env> <image-repository> <image-tag> [update-modules]}"
IMAGE_REPOSITORY="${2:?image repository required}"
IMAGE_TAG="${3:?image tag required}"
UPDATE_MODULES="${4:-}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAMESPACE="${NAMESPACE:-odoo-${ENVIRONMENT}}"
RELEASE="${RELEASE:-odoo-platform}"
ACCESS_MODE="${ACCESS_MODE:-address}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"

access_args=(--set-string access.mode="$ACCESS_MODE")
grafana_url=""
if [ "$ACCESS_MODE" = "address" ]; then
  echo "Waiting for the load balancer address of ${NAMESPACE}..."
  address="$("$ROOT/scripts/ensure-alb.sh" "$NAMESPACE")"
  access_args+=(--set-string access.address="$address")
  grafana_address="$(kubectl -n "$MONITORING_NAMESPACE" get ingress alb-address \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [ -n "$grafana_address" ]; then
    grafana_url="http://${grafana_address}"
    access_args+=(--set-string keycloak.grafanaUrl="$grafana_url")
  fi
fi

helm upgrade --install "$RELEASE" "$ROOT/helm/odoo-platform" \
  --namespace "$NAMESPACE" \
  -f "$ROOT/environments/${ENVIRONMENT}/values.yaml" \
  "${access_args[@]}" \
  --set-string odoo.image.repository="$IMAGE_REPOSITORY" \
  --set-string odoo.image.tag="$IMAGE_TAG" \
  --set-string odoo.init.updateModules="$UPDATE_MODULES" \
  ${MINIO_IMAGE:+--set-string minio.image="$MINIO_IMAGE"} \
  --wait --timeout 30m

kubectl -n "$NAMESPACE" rollout status deployment/odoo --timeout=10m
kubectl -n "$NAMESPACE" rollout status deployment/keycloak --timeout=10m 2>/dev/null || true

if [ "$ACCESS_MODE" = "address" ]; then
  if kubectl -n "$NAMESPACE" get deployment keycloak >/dev/null 2>&1; then
    "$ROOT/scripts/configure-keycloak.sh" "$NAMESPACE" "http://${address}" "$grafana_url"
  fi
  echo
  echo "Platform URLs (plain HTTP; the ALB name can take a few minutes to resolve the first time):"
  echo "  Odoo:           http://${address}/"
  echo "  Keycloak:       http://${address}:8080/admin"
  if kubectl -n "$NAMESPACE" get ingress minio-console >/dev/null 2>&1; then
    echo "  MinIO console:  http://${address}:9001/"
  fi
  [ -n "$grafana_url" ] && echo "  Grafana:        ${grafana_url}/"
fi
exit 0
