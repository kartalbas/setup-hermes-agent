{{/* Names. The unit's name is fixed by the identity law, so it is read from the chart
     rather than composed, and every object is prefixed with it. */}}
{{- define "unit.name" -}}{{ .Chart.Name }}{{- end -}}

{{- define "unit.stage" -}}{{ required "stage must be set" .Values.stage }}{{- end -}}

{{- define "unit.labels" -}}
app.kubernetes.io/name: {{ include "unit.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
hostyour.cloud/unit: {{ include "unit.name" . }}
hostyour.cloud/stage: {{ include "unit.stage" . }}
{{- end -}}

{{/* An image reference that gate G8 accepts: a tag that is not "latest". The release
     pipeline replaces the tag with a digest when it pins a stage. */}}
{{- define "unit.image" -}}
{{- $registry := .root.Values.image.registry -}}
{{- if $registry -}}{{ $registry }}/{{ end }}{{ .spec.repository }}:{{ required "an image tag is required — an untagged reference is :latest, which gate G8 rejects" .spec.tag }}
{{- end -}}

{{/* The env every agent container shares. HERMES_TIMEZONE is not optional: a container
     is UTC, and without it the morning digests and the nightly session reset run two
     hours off with nothing to point at. */}}
{{- define "unit.commonEnv" -}}
- name: HERMES_TIMEZONE
  value: {{ .Values.timezone | quote }}
- name: TZ
  value: {{ .Values.timezone | quote }}
- name: HERMES_GATEWAY_EXTERNAL_SUPERVISOR
  value: "1"
{{- end -}}
