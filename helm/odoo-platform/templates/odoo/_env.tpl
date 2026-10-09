{{/* Environment shared by the Odoo deployment, the init job and the cronjob */}}
{{- define "op.odooEnv" -}}
- name: PGHOST
  value: {{ include "op.dbHost" . }}
- name: PGPORT
  value: {{ include "op.dbPort" . | quote }}
- name: PGUSER
  value: {{ .Values.databases.odoo.user }}
{{ include "op.secretEnv" (list "PGPASSWORD" "odoo-db-password" .) }}
{{ include "op.secretEnv" (list "ODOO_ADMIN_PASSWORD" "odoo-admin-password" .) }}
- name: MINIO_ENDPOINT
  value: {{ include "op.s3Endpoint" . }}
- name: MINIO_REGION
  value: {{ .Values.minio.region }}
- name: MINIO_BUCKET
  value: {{ .Values.odoo.s3.bucket }}
{{ include "op.secretEnv" (list "MINIO_ACCESS_KEY" "minio-root-user" .) }}
{{ include "op.secretEnv" (list "MINIO_SECRET_KEY" "minio-root-password" .) }}
{{- end }}

{{/* Writes the runtime odoo.conf (template + admin_passwd) into /etc/odoo */}}
{{- define "op.odooConfigInit" -}}
- name: render-config
  image: "{{ .Values.odoo.image.repository }}:{{ .Values.odoo.image.tag }}"
  imagePullPolicy: {{ .Values.odoo.image.pullPolicy }}
  command:
    - bash
    - -c
    - |
      cp /etc/odoo-template/odoo.conf /etc/odoo/odoo.conf
      printf 'admin_passwd = %s\n' "$ODOO_ADMIN_PASSWORD" >> /etc/odoo/odoo.conf
  env:
    {{- include "op.secretEnv" (list "ODOO_ADMIN_PASSWORD" "odoo-admin-password" .) | nindent 4 }}
  volumeMounts:
    - name: config-template
      mountPath: /etc/odoo-template
    - name: config
      mountPath: /etc/odoo
{{- end }}
