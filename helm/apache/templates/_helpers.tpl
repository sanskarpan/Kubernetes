{{/*
_helpers.tpl — Apache Helm Chart Template Helpers
==================================================
Template functions defined here are available to all templates in this chart.
Files whose names begin with an underscore are not rendered as Kubernetes
manifests — they exist solely to define reusable helpers.

Usage: {{ include "apache.fullname" . }}
*/}}

{{/*
apache.name
-----------
Expand the name of the chart. If the user sets .Values.nameOverride, that takes
precedence. The result is truncated to 63 characters because Kubernetes DNS label
names have a 63-character maximum length.

Example output: "apache"
*/}}
{{- define "apache.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
apache.fullname
---------------
Create a fully qualified app name by combining the Helm release name and the
chart name. This avoids name collisions when multiple releases of the same chart
are installed in the same namespace.

If .Values.fullnameOverride is set, it is used verbatim (truncated to 63 chars).
If the release name already contains the chart name, we don't duplicate it.

Examples:
  Release "my-release", chart "apache" → "my-release-apache"
  Release "apache", chart "apache"     → "apache"             (no duplication)
  fullnameOverride "my-app"            → "my-app"
*/}}
{{- define "apache.fullname" -}}
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
apache.chart
------------
Produces the "chart label" value in the format "chart-name-version".
Used in the helm.sh/chart annotation to record which chart version created
the resource — useful for auditing and debugging.

Example output: "apache-0.2.0"
*/}}
{{- define "apache.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
apache.labels
-------------
Standard set of labels applied to ALL resources in this chart.
These labels follow the app.kubernetes.io/* label convention:
  https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/

Labels here are IMMUTABLE on Deployments/StatefulSets (selector labels).
Do NOT add user-supplied labels here — add them only to the pod template metadata.

Fields:
  app.kubernetes.io/name        — The name of the application (the chart name)
  app.kubernetes.io/instance    — The Helm release name (unique per installation)
  app.kubernetes.io/version     — The version of the application (appVersion)
  app.kubernetes.io/component   — The role this resource plays (e.g., webserver)
  app.kubernetes.io/part-of     — The higher-level application this belongs to
  app.kubernetes.io/managed-by  — The tool managing this resource (Helm)
  helm.sh/chart                 — Chart name + version for auditing
*/}}
{{- define "apache.labels" -}}
helm.sh/chart: {{ include "apache.chart" . }}
app.kubernetes.io/name: {{ include "apache.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/component: webserver
app.kubernetes.io/part-of: {{ include "apache.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
apache.selectorLabels
---------------------
A MINIMAL subset of labels used as the Deployment selector and Pod template labels.
These labels MUST be stable across upgrades — changing them requires deleting and
re-creating the Deployment. Do NOT include version or chart labels here, as those
change with every release and would break the selector immutability requirement.

These same labels are used by:
  - Deployment.spec.selector.matchLabels
  - Deployment.spec.template.metadata.labels (must be a superset)
  - Service.spec.selector
  - PodDisruptionBudget.spec.selector
  - HPA.spec.scaleTargetRef (via Deployment name)
*/}}
{{- define "apache.selectorLabels" -}}
app.kubernetes.io/name: {{ include "apache.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
apache.serviceAccountName
--------------------------
Determine the name of the ServiceAccount to use for the Deployment pods.

Logic:
  1. If serviceAccount.create is true and serviceAccount.name is set → use the provided name
  2. If serviceAccount.create is true and name is empty → generate from apache.fullname
  3. If serviceAccount.create is false and name is set → use the provided name (existing SA)
  4. If serviceAccount.create is false and name is empty → use "default" (not recommended)
*/}}
{{- define "apache.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "apache.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
apache.image
------------
Construct the full image reference, preferring digest over tag for production
reproducibility. When a digest is provided, the tag is ignored.

Examples:
  digest set:  "httpd@sha256:abc123..."
  tag set:     "httpd:2.4"
  neither:     "httpd:2.4"   (falls back to Chart.AppVersion)
*/}}
{{- define "apache.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end -}}
{{- end }}
