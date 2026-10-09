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

{{/* op.ingressAnnotations <root> <extra annotations dict> */}}
{{- define "op.ingressAnnotations" -}}
{{- $a := merge (dict) (default (dict) (index . 1)) (index . 0).Values.ingress.annotations -}}
{{- with $a }}
annotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "op.monitoringEnabled" -}}
{{- if and .Values.monitoring.enabled (.Capabilities.APIVersions.Has "monitoring.coreos.com/v1") -}}true{{- end -}}
{{- end }}
