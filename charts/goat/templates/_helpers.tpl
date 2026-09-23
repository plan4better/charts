{{/* /home/p4b/goat/charts/goat/templates/_helpers.tpl */}}

{{/*
Expand the name of the chart.
*/}}
{{- define "goat.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
Truncated at 63 chars (DNS limit).
*/}}
{{- define "goat.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart identifier label.
*/}}
{{- define "goat.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every chart-owned resource.
*/}}
{{- define "goat.labels" -}}
helm.sh/chart: {{ include "goat.chart" . }}
{{ include "goat.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: goat
{{- with .Values.global.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels — must be stable across upgrades.
*/}}
{{- define "goat.selectorLabels" -}}
app.kubernetes.io/name: {{ include "goat.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Per-service labels — adds `app.kubernetes.io/component`.
Usage: {{ include "goat.serviceLabels" (dict "context" . "component" "core") }}
*/}}
{{- define "goat.serviceLabels" -}}
{{ include "goat.labels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Per-service selector labels.
*/}}
{{- define "goat.serviceSelectorLabels" -}}
{{ include "goat.selectorLabels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Per-service fullname — appends component to release fullname.
Usage: {{ include "goat.serviceFullname" (dict "context" . "component" "core") }}
*/}}
{{- define "goat.serviceFullname" -}}
{{- $maxFullnameLen := sub 62 (len .component) | int -}}
{{- $fullname := include "goat.fullname" .context | trunc $maxFullnameLen | trimSuffix "-" -}}
{{- printf "%s-%s" $fullname .component | trimSuffix "-" -}}
{{- end }}

{{/*
Render an image reference. Honors global.imageRegistry as a mirror override.
Usage: {{ include "goat.image" (dict "image" .Values.core.image "global" .Values.global "root" $) }}
*/}}
{{- define "goat.image" -}}
{{- $registry := default .image.registry .global.imageRegistry -}}
{{- $repo := .image.repository -}}
{{- $tag := default .root.Chart.AppVersion .image.tag -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry $repo $tag -}}
{{- else -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
{{- end }}

{{/*
imagePullSecrets — rendered from .Values.global.imagePullSecrets only.
Per-service overrides are not supported in v1; add them if a real use case appears.
*/}}
{{- define "goat.imagePullSecrets" -}}
{{- $secrets := .Values.global.imagePullSecrets -}}
{{- if $secrets -}}
imagePullSecrets:
{{ toYaml $secrets | indent 2 }}
{{- end -}}
{{- end }}

{{/*
Legacy per-worker claim name (windmill tools/workflows `persistence`, the
`data.enabled: false` fallback). Params: root, worker ("tools" | "workflows").
*/}}
{{- define "goat.windmill.workerPvc.name" -}}
{{- printf "%s-windmill-%s-data" (include "goat.fullname" .root) .worker -}}
{{- end }}

{{/*
Whether this release renders the per-worker claim (the fallback used only
when `data.enabled: false`). Shared by the pvc.yaml templates and the guard
so the two can never disagree. Params: root, worker.
*/}}
{{- define "goat.windmill.workerPvc.rendered" -}}
{{- $w := index .root.Values.windmill.workers .worker -}}
{{- if and (not .root.Values.data.enabled) $w.enabled $w.persistence.enabled (not $w.persistence.existingClaim) -}}
true
{{- end -}}
{{- end }}

{{/*
Shared data volume — claim name. Honors data.existingClaim.
*/}}
{{- define "goat.data.claimName" -}}
{{- if .Values.data.existingClaim -}}
{{- .Values.data.existingClaim -}}
{{- else -}}
{{- printf "%s-data" (include "goat.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Shared data volume — the pod-level volumes entry. Volume name is `goat-data`
everywhere, so the mount helpers below can reference it by name.
*/}}
{{- define "goat.data.volume" -}}
- name: goat-data
  persistentVolumeClaim:
    claimName: {{ include "goat.data.claimName" . }}
{{- end }}

{{/*
Shared data volume — full read-write mount. For geoapi, processes and the
tools/workflows workers. geoapi is deliberately NOT read-only: it writes
features into DuckLake and deletes a layer's PMTiles on save.
*/}}
{{- define "goat.data.mounts.full" -}}
- name: goat-data
  mountPath: /app/data
{{- end }}

{{/*
Shared data volume — catalog's mount: just the catalog subtree, read-only.
User data on this volume is not the catalog service's business.
*/}}
{{- define "goat.data.mounts.catalog" -}}
- name: goat-data
  mountPath: /app/data/catalog
  subPath: catalog
  readOnly: true
{{- end }}

{{/*
Shared data volume — core's mounts: the catalog mirror and the geoip database,
both read-only. Core only ever reads from this volume.
*/}}
{{- define "goat.data.mounts.core" -}}
- name: goat-data
  mountPath: /app/data/catalog
  subPath: catalog
  readOnly: true
- name: goat-data
  mountPath: /app/data/geoip
  subPath: geoip
  readOnly: true
{{- end }}

{{/*
The browser-facing base URL of the web app. Used for the catalog's
"Open in GOAT" links and as its default CORS origin. Never cluster DNS —
a browser has to be able to resolve it. Falls back to web.ingress (so a
realistic ingress-based install still derives the real host instead of
staying on the NEXTAUTH_URL default of localhost:3000) before finally
falling back to the NEXTAUTH_URL config value itself.
*/}}
{{- define "goat.web.publicUrl" -}}
{{- .Values.web.auth.publicUrl | default (include "goat.ingressUrl" (dict "ingress" .Values.web.ingress)) | default .Values.web.config.NEXTAUTH_URL -}}
{{- end }}


{{/*
In-cluster URL of the processes service, or empty when it is not deployed.
Core and geoapi both POST here to start background jobs (layer and bundle
cleanup, bundle import, the rebuild a bundle edit needs). Unset, those
triggers fail silently while everything else keeps working.
Service port is 80, so no port suffix.
*/}}
{{- define "goat.processes.url" -}}
{{- if .Values.processes.enabled -}}
{{- printf "http://%s" (include "goat.serviceFullname" (dict "context" . "component" "processes")) -}}
{{- end -}}
{{- end }}

{{/*
Derive a browser-facing URL from a service's ingress block: scheme from
whether TLS is configured, host from the first entry. Empty when the ingress
is off or has no hosts.
Usage: {{ include "goat.ingressUrl" (dict "ingress" .Values.core.ingress) }}
*/}}
{{- define "goat.ingressUrl" -}}
{{- $ing := .ingress -}}
{{- if and $ing.enabled $ing.hosts -}}
{{- $scheme := ternary "https" "http" (gt (len $ing.tls) 0) -}}
{{- printf "%s://%s" $scheme (first $ing.hosts).host -}}
{{- end -}}
{{- end }}
