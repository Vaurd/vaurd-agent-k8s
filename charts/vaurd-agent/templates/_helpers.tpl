{{/* Chart name, overridable. */}}
{{- define "vaurd-agent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified release name used as the prefix for every object. */}}
{{- define "vaurd-agent.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Labels attached to every object. */}}
{{- define "vaurd-agent.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "vaurd-agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: vaurd-agent
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* Selector labels for a component. Call as (dict "ctx" $ "component" "core"). */}}
{{- define "vaurd-agent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vaurd-agent.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* Full image reference for a component. Call as (dict "ctx" $ "component" "core"). */}}
{{- define "vaurd-agent.image" -}}
{{- $img := .ctx.Values.image -}}
{{- $repo := index $img .component -}}
{{- $tag := default $img.tag (index .ctx.Values .component).image.tag -}}
{{- if $img.registry -}}
{{- printf "%s/%s:%s" $img.registry $repo $tag -}}
{{- else -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
{{- end -}}

{{/* Name of the Secret holding config.yml. */}}
{{- define "vaurd-agent.configSecretName" -}}
{{- default (printf "%s-config" (include "vaurd-agent.fullname" .)) .Values.config.existingSecret -}}
{{- end -}}

{{/* Name of the Secret holding NATS credentials for the bundled server. */}}
{{- define "vaurd-agent.natsSecretName" -}}
{{- printf "%s-nats-auth" (include "vaurd-agent.fullname" .) -}}
{{- end -}}

{{/* NATS client endpoint, bundled or external. */}}
{{- define "vaurd-agent.natsEndpoint" -}}
{{- if .Values.nats.enabled -}}
{{- printf "nats://%s-nats:4222" (include "vaurd-agent.fullname" .) -}}
{{- else -}}
{{- required "nats.externalEndpoint is required when nats.enabled is false" .Values.nats.externalEndpoint -}}
{{- end -}}
{{- end -}}

{{/* Name of the shared data PVC, chart-managed or user-supplied. */}}
{{- define "vaurd-agent.dataClaimName" -}}
{{- default (printf "%s-data" (include "vaurd-agent.fullname" .)) .Values.persistence.existingClaim -}}
{{- end -}}

{{/* Volumes shared by all three components. */}}
{{- define "vaurd-agent.volumes" -}}
- name: config
  secret:
    secretName: {{ include "vaurd-agent.configSecretName" . }}
    defaultMode: 0440
- name: agent-data
  persistentVolumeClaim:
    claimName: {{ include "vaurd-agent.dataClaimName" . }}
- name: tmp
  emptyDir: {}
{{- end -}}
