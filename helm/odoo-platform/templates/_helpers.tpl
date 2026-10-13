{{- define "op.labels" -}}
app.kubernetes.io/part-of: odoo-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/* op.selector <root> <component> */}}
{{- define "op.selector" -}}
app.kubernetes.io/instance: {{ (index . 0).Release.Name }}
app.kubernetes.io/component: {{ index . 1 }}
{{- end }}

{{/* op.componentLabels <root> <component> */}}
{{- define "op.componentLabels" -}}
{{ include "op.labels" (index . 0) }}
app.kubernetes.io/component: {{ index . 1 }}
{{- end }}

{{- define "op.monitoringLabels" -}}
{{- with .Values.monitoring.labels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "op.dbHost" -}}
{{- if .Values.postgres.enabled -}}
postgres.{{ .Release.Namespace }}.svc.cluster.local
{{- else -}}
{{ required "externalDatabase.host is required when postgres.enabled=false" .Values.externalDatabase.host }}
{{- end -}}
{{- end }}

{{- define "op.dbPort" -}}
{{- if .Values.postgres.enabled }}5432{{ else }}{{ .Values.externalDatabase.port }}{{ end -}}
{{- end }}

{{- define "op.s3Endpoint" -}}
{{- if .Values.minio.enabled -}}
http://minio.{{ .Release.Namespace }}.svc.cluster.local:9000
{{- else -}}
{{ .Values.odoo.s3.endpoint }}
{{- end -}}
{{- end }}

{{- define "op.keycloakInternalUrl" -}}
http://keycloak.{{ .Release.Namespace }}.svc.cluster.local:8080
{{- end }}

{{/* op.secretEnv <envName> <secretKey> <root> */}}
{{- define "op.secretEnv" -}}
- name: {{ index . 0 }}
  valueFrom:
    secretKeyRef:
      name: {{ (index . 2).Values.existingSecret }}
      key: {{ index . 1 }}
{{- end }}

{{- define "op.addressMode" -}}
{{- if eq .Values.access.mode "address" -}}true
{{- else if ne .Values.access.mode "domains" -}}{{ fail "access.mode must be address or domains" }}
{{- end -}}
{{- end }}

{{- define "op.address" -}}
{{ required "access.address is required when access.mode=address (scripts/deploy-app.sh sets it)" .Values.access.address }}
{{- end }}

{{/* Public URLs, as browsers reach them */}}
{{- define "op.odooUrl" -}}
{{- if include "op.addressMode" . -}}
http://{{ include "op.address" . }}
{{- else -}}
https://{{ .Values.domains.odoo }}
{{- end -}}
{{- end }}

{{- define "op.keycloakUrl" -}}
{{- if include "op.addressMode" . -}}
http://{{ include "op.address" . }}:{{ .Values.access.ports.keycloak }}
{{- else -}}
https://{{ .Values.domains.keycloak }}
{{- end -}}
{{- end }}

{{- define "op.minioConsoleUrl" -}}
{{- if include "op.addressMode" . -}}
http://{{ include "op.address" . }}:{{ .Values.access.ports.minioConsole }}
{{- else -}}
https://{{ .Values.domains.minioConsole }}
{{- end -}}
{{- end }}

{{/* op.ingressAnnotations <root> <extra annotations dict> <port in address mode>
     Values and extra annotations win over the computed ones. */}}
{{- define "op.ingressAnnotations" -}}
{{- $root := index . 0 -}}
{{- $computed := dict "alb.ingress.kubernetes.io/group.name" $root.Release.Namespace -}}
{{- if include "op.addressMode" $root -}}
{{- $_ := set $computed "alb.ingress.kubernetes.io/listen-ports" (printf "[{\"HTTP\": %v}]" (index . 2)) -}}
{{- else -}}
{{- $_ := set $computed "alb.ingress.kubernetes.io/listen-ports" "[{\"HTTP\": 80}, {\"HTTPS\": 443}]" -}}
{{- $_ := set $computed "alb.ingress.kubernetes.io/ssl-redirect" "443" -}}
{{- with $root.Values.ingress.certificateArn }}
{{- $_ := set $computed "alb.ingress.kubernetes.io/certificate-arn" . -}}
{{- end -}}
{{- end -}}
{{- $a := merge (dict) (default (dict) (index . 1)) $root.Values.ingress.annotations $computed -}}
annotations:
  {{- toYaml $a | nindent 2 }}
{{- end }}

{{/* op.ingressTls / op.ingressHost <root> <hostname>: domains mode only */}}
{{- define "op.ingressTls" -}}
{{- if not (include "op.addressMode" (index . 0)) -}}
tls:
  - hosts: [{{ index . 1 | quote }}]
{{- end }}
{{- end }}

{{- define "op.ingressHost" -}}
{{- if not (include "op.addressMode" (index . 0)) -}}
host: {{ index . 1 | quote }}
{{- end }}
{{- end }}

{{- define "op.monitoringEnabled" -}}
{{- if and .Values.monitoring.enabled (.Capabilities.APIVersions.Has "monitoring.coreos.com/v1") -}}true{{- end -}}
{{- end }}
