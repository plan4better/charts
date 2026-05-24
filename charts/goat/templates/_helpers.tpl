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
