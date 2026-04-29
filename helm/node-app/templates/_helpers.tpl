{{/*
_helpers.tpl — Node App Helm Chart Template Helpers
====================================================
Template functions for the node-app chart. Mirrors the apache chart helper
pattern for consistency across charts in this repository.
*/}}

{{/*
node-app.name
-------------
Expand the chart name. Uses nameOverride if set, otherwise .Chart.Name.
Truncated to 63 characters (Kubernetes DNS label limit).
*/}}
{{- define "node-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
node-app.fullname
-----------------
Create a fully qualified resource name: "<release>-<chart>" or just "<release>"
if the release name already contains the chart name.
fullnameOverride takes precedence over all other logic.
*/}}
{{- define "node-app.fullname" -}}
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
node-app.chart
--------------
Produce the chart label value "chart-name-version".
Used in the helm.sh/chart annotation for release auditing.
*/}}
{{- define "node-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
node-app.labels
---------------
Full set of labels applied to ALL resources. Uses the app.kubernetes.io/* convention.
These labels are used for resource discovery, cost allocation, and observability.
*/}}
{{- define "node-app.labels" -}}
helm.sh/chart: {{ include "node-app.chart" . }}
app.kubernetes.io/name: {{ include "node-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/component: application
app.kubernetes.io/part-of: {{ include "node-app.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
node-app.selectorLabels
-----------------------
Minimal IMMUTABLE labels used for Deployment.spec.selector and pod template labels.
Do NOT change these after the first deploy — the selector is immutable on Deployments.
*/}}
{{- define "node-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "node-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
node-app.serviceAccountName
----------------------------
Determine the ServiceAccount name for the pod:
  - If create=true and name is set → use that name
  - If create=true and name is empty → generate from fullname
  - If create=false and name is set → use that existing SA
  - If create=false and name is empty → fall back to "default" (not recommended)
*/}}
{{- define "node-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "node-app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
node-app.image
--------------
Construct the full image reference.
Prefers digest over tag for production reproducibility.
Falls back to Chart.AppVersion if neither digest nor tag is provided.
*/}}
{{- define "node-app.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end -}}
{{- end }}
