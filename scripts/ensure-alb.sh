#!/usr/bin/env bash
# Create (once) the ALB that serves a namespace and print its address.
#
# Used with ACCESS_MODE=address: Keycloak, Odoo and Grafana need their public
# URL before they are deployed, so the ALB is created first by a small
# "alb-address" ingress. Every ingress in the namespace joins the same ALB
# (group.name = namespace), so the address stays the same across deploys for
# as long as this ingress exists.
#
# Usage: scripts/ensure-alb.sh <namespace>     (prints the address on stdout)
set -euo pipefail

NAMESPACE="${1:?usage: $0 <namespace>}"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n "$NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: alb-address
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/group.name: ${NAMESPACE}
    alb.ingress.kubernetes.io/group.order: "-100"
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
    alb.ingress.kubernetes.io/actions.alb-ready: >-
      {"type":"fixed-response","fixedResponseConfig":{"contentType":"text/plain","statusCode":"200","messageBody":"ok"}}
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /alb-ready
            pathType: Exact
            backend:
              service:
                name: alb-ready
                port:
                  name: use-annotation
EOF

for _ in $(seq 1 60); do
  address="$(kubectl -n "$NAMESPACE" get ingress alb-address -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
  if [ -n "$address" ]; then
    echo "$address"
    exit 0
  fi
  sleep 5
done

echo "No address on ingress ${NAMESPACE}/alb-address after 5 minutes. Check the AWS Load Balancer Controller:" >&2
kubectl -n "$NAMESPACE" describe ingress alb-address >&2 || true
exit 1
