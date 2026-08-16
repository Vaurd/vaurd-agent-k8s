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

{{/*
Name of the Secret holding the NATS credentials: the one the user brought via
nats.auth.existingNatsSecret, or the one this chart manages.
*/}}
{{- define "vaurd-agent.natsSecretName" -}}
{{- default (printf "%s-nats-auth" (include "vaurd-agent.fullname" .)) .Values.nats.auth.existingNatsSecret -}}
{{- end -}}

{{/* Keys to read the credentials from. Only configurable for a user-supplied Secret. */}}
{{- define "vaurd-agent.natsSecretUsernameKey" -}}
{{- if .Values.nats.auth.existingNatsSecret -}}
{{- default "username" .Values.nats.auth.existingNatsSecretUsernameKey -}}
{{- else -}}
username
{{- end -}}
{{- end -}}

{{- define "vaurd-agent.natsSecretPasswordKey" -}}
{{- if .Values.nats.auth.existingNatsSecret -}}
{{- default "password" .Values.nats.auth.existingNatsSecretPasswordKey -}}
{{- else -}}
password
{{- end -}}
{{- end -}}

{{/*
The NATS password in clear text, for rendering into config.yml and into the
chart-managed Secret. Resolved in this order:

  1. nats.auth.password, when set explicitly.
  2. The value already stored in the Secret in the cluster — this is what keeps
     a generated password stable across `helm upgrade`.
  3. A freshly generated password, when this chart manages the Secret and the
     bundled server is enabled.

Memoised on .Values so that every call inside one render agrees: config.yml,
the Secret and the pods' checksum annotation must all see the same password.

Note that step 2 relies on `lookup`, which returns nothing under `helm template`
and `--dry-run`. A generated password is therefore re-generated on every such
render; set nats.auth.password explicitly if you render the chart yourself or
deploy it through a GitOps tool.
*/}}
{{- define "vaurd-agent.natsPassword" -}}
{{- if not (hasKey .Values "natsResolvedPassword") -}}
{{- $existing := (lookup "v1" "Secret" .Release.Namespace (include "vaurd-agent.natsSecretName" .)) | default dict -}}
{{- $data := $existing.data | default dict -}}
{{- $key := include "vaurd-agent.natsSecretPasswordKey" . -}}
{{- $password := "" -}}
{{- if .Values.nats.auth.password -}}
{{- $password = .Values.nats.auth.password -}}
{{- else if hasKey $data $key -}}
{{- $password = index $data $key | b64dec -}}
{{- else if .Values.nats.auth.existingNatsSecret -}}
{{- $password = required (printf "Secret %q has no %q key, or could not be read (lookup does not work under `helm template`). Set nats.auth.password, or supply your own config Secret with config.existingSecret." .Values.nats.auth.existingNatsSecret $key) "" -}}
{{- else if .Values.nats.enabled -}}
{{- $password = randAlphaNum 32 -}}
{{- else -}}
{{- $password = required "nats.auth.password is required when nats.enabled is false — the chart only generates a password for the NATS server it deploys itself" "" -}}
{{- end -}}
{{- $_ := set .Values "natsResolvedPassword" $password -}}
{{- end -}}
{{- .Values.natsResolvedPassword -}}
{{- end -}}

{{/* The NATS username in clear text, for rendering into config.yml. */}}
{{- define "vaurd-agent.natsUsername" -}}
{{- if .Values.nats.auth.existingNatsSecret -}}
{{- $existing := (lookup "v1" "Secret" .Release.Namespace .Values.nats.auth.existingNatsSecret) | default dict -}}
{{- $data := $existing.data | default dict -}}
{{- $key := include "vaurd-agent.natsSecretUsernameKey" . -}}
{{- if hasKey $data $key -}}
{{- index $data $key | b64dec -}}
{{- else -}}
{{- /* Never fall back to nats.auth.username here: the server reads its username
       straight from the Secret, so a guess would fail authentication silently. */ -}}
{{- required (printf "Secret %q has no %q key, or could not be read (lookup does not work under `helm template`). Supply your own config Secret with config.existingSecret if you render the chart offline." .Values.nats.auth.existingNatsSecret $key) "" -}}
{{- end -}}
{{- else -}}
{{- required "nats.auth.username is required" .Values.nats.auth.username -}}
{{- end -}}
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
