{{/* /home/p4b/goat/charts/goat/templates/_secrets.tpl */}}

{{/*
Resolve the secret NAME holding the postgres user credentials.
- If postgresql.cluster.enabled: CNPG creates a "<cluster>-app" secret containing username + password keys.
- Else if postgresql.external.existingSecret is set: use that.
- Else: fail loudly at render time.

Returns the secret name (string). Caller is responsible for the keys.
*/}}
{{- define "goat.postgresql.secretName" -}}
{{- if .Values.postgresql.cluster.enabled -}}
{{- printf "%s-pg-app" (include "goat.fullname" .) -}}
{{- else if .Values.postgresql.external.existingSecret -}}
{{- .Values.postgresql.external.existingSecret -}}
{{- else -}}
{{- fail "postgresql.external.existingSecret is required when postgresql.cluster.enabled is false" -}}
{{- end -}}
{{- end -}}

{{/*
Key inside the postgres secret for the username.
- Bundled (CNPG): always "username"
- External: configurable via postgresql.external.existingSecretUserKey (default "username")
*/}}
{{- define "goat.postgresql.userKey" -}}
{{- if .Values.postgresql.cluster.enabled -}}
username
{{- else -}}
{{- default "username" .Values.postgresql.external.existingSecretUserKey -}}
{{- end -}}
{{- end -}}

{{/*
Key inside the postgres secret for the password.
*/}}
{{- define "goat.postgresql.passwordKey" -}}
{{- if .Values.postgresql.cluster.enabled -}}
password
{{- else -}}
{{- default "password" .Values.postgresql.external.existingSecretPasswordKey -}}
{{- end -}}
{{- end -}}

{{/*
Resolve the postgres HOST.
- Bundled: <release>-<chart>-pg-rw (CNPG service naming convention)
- External: postgresql.external.host
*/}}
{{- define "goat.postgresql.host" -}}
{{- if .Values.postgresql.cluster.enabled -}}
{{- printf "%s-pg-rw" (include "goat.fullname" .) -}}
{{- else -}}
{{- required "postgresql.external.host is required when postgresql.cluster.enabled is false" .Values.postgresql.external.host -}}
{{- end -}}
{{- end -}}

{{/*
Postgres database name. Same for bundled and external in v1.
*/}}
{{- define "goat.postgresql.database" -}}
{{- default "goat" .Values.postgresql.external.database -}}
{{- end -}}

{{/*
Postgres port.
*/}}
{{- define "goat.postgresql.port" -}}
{{- default 5432 .Values.postgresql.external.port | toString -}}
{{- end -}}
