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

{{/*
Windmill database helpers.

Windmill is bootstrap-heavy: its server runs migrations that CREATE ROLE +
GRANT inside whichever database it points at. Running those against the
shared goat DB (as `windmill.db.reuseGoatConnection: true` does) is
disruptive — windmill writes ~100 tables in the goat user's default schema
and the migrations require role-creation privileges that the goat owner
typically does not have.

Set `windmill.db.reuseGoatConnection: false` and fill `windmill.db.external.*`
to point windmill at its own database, provisioned separately.

When reuseGoatConnection is true, the helpers below fall back to the
goat postgres helpers above so the chart still renders without windmill
db config.
*/}}

{{- define "windmill.postgresql.secretName" -}}
{{- if .Values.windmill.db.reuseGoatConnection -}}
{{- include "goat.postgresql.secretName" . -}}
{{- else if .Values.windmill.db.external.existingSecret -}}
{{- .Values.windmill.db.external.existingSecret -}}
{{- else -}}
{{- fail "windmill.db.external.existingSecret is required when windmill.db.reuseGoatConnection is false" -}}
{{- end -}}
{{- end -}}

{{- define "windmill.postgresql.userKey" -}}
{{- if .Values.windmill.db.reuseGoatConnection -}}
{{- include "goat.postgresql.userKey" . -}}
{{- else -}}
{{- default "username" .Values.windmill.db.external.existingSecretUserKey -}}
{{- end -}}
{{- end -}}

{{- define "windmill.postgresql.passwordKey" -}}
{{- if .Values.windmill.db.reuseGoatConnection -}}
{{- include "goat.postgresql.passwordKey" . -}}
{{- else -}}
{{- default "password" .Values.windmill.db.external.existingSecretPasswordKey -}}
{{- end -}}
{{- end -}}

{{- define "windmill.postgresql.host" -}}
{{- if .Values.windmill.db.reuseGoatConnection -}}
{{- include "goat.postgresql.host" . -}}
{{- else -}}
{{- required "windmill.db.external.host is required when windmill.db.reuseGoatConnection is false" .Values.windmill.db.external.host -}}
{{- end -}}
{{- end -}}

{{- define "windmill.postgresql.port" -}}
{{- if .Values.windmill.db.reuseGoatConnection -}}
{{- include "goat.postgresql.port" . -}}
{{- else -}}
{{- default 5432 .Values.windmill.db.external.port | toString -}}
{{- end -}}
{{- end -}}

{{- define "windmill.postgresql.database" -}}
{{- if .Values.windmill.db.reuseGoatConnection -}}
{{- include "goat.postgresql.database" . -}}
{{- else -}}
{{- default "windmill" .Values.windmill.db.external.database -}}
{{- end -}}
{{- end -}}
