{{/*
Expand the name of the chart.
*/}}
{{- define "solo-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "solo-app.fullname" -}}
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
Chart label
*/}}
{{- define "solo-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels (standard Kubernetes + Solo Empire required labels)
*/}}
{{- define "solo-app.labels" -}}
helm.sh/chart: {{ include "solo-app.chart" . }}
{{ include "solo-app.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ .Values.app.partOf | default "solo-empire" | quote }}
app.kubernetes.io/component: {{ .Values.app.component | default "web" | quote }}
solo.empire/team: {{ required "app.team is required" .Values.app.team | quote }}
solo.empire/environment: {{ required "app.environment is required" .Values.app.environment | quote }}
solo.empire/region: {{ .Values.app.region | default "local" | quote }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "solo-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "solo-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name
*/}}
{{- define "solo-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "solo-app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Container image reference (tag or digest; never default to latest)
*/}}
{{- define "solo-app.image" -}}
{{- if .Values.image.digest }}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else }}
{{- $tag := required "image.tag is required (do not use latest)" .Values.image.tag }}
{{- if eq $tag "latest" }}
{{- fail "image.tag must not be 'latest'; use a version tag or digest" }}
{{- end }}
{{- printf "%s:%s" .Values.image.repository $tag }}
{{- end }}
{{- end }}

{{/*
Kubernetes Secret name produced by ExternalSecret and consumed by the Pod.
When externalSecrets.enabled=true, Deployment.envFrom.secretRef uses this
exact name so the app always receives the synced secret.
Override with externalSecrets.targetSecretName only when intentionally
sharing a secret across releases.
*/}}
{{- define "solo-app.externalSecretName" -}}
{{- if .Values.externalSecrets.targetSecretName }}
{{- .Values.externalSecrets.targetSecretName }}
{{- else }}
{{- printf "%s-secrets" (include "solo-app.fullname" .) }}
{{- end }}
{{- end }}
