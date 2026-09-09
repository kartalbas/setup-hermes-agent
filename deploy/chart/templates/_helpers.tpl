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

{{/* An image reference, resolved from the builds[] pin the release pipeline's bump
     writes into values-<stage>.yaml. Reading the tag from anywhere else would mean
     the bump writes a pin nothing reads, and the deployed image would drift away
     from the released one with nothing to show for it.

     Refuses rather than defaults: a missing pin is a chart that was never released,
     and the message says which file supplies it. */}}
{{- define "unit.image" -}}
{{- $root := .root -}}
{{- $want := .image -}}
{{- $tag := "" -}}
{{- range $root.Values.builds -}}
{{- if eq .image $want -}}{{- $tag = .tag -}}{{- end -}}
{{- end -}}
{{- if not $tag -}}
{{- fail (printf "no builds[] entry pins the image %q — the release pipeline's bump writes those into values-<stage>.yaml, and a chart with no pin has nothing to deploy" $want) -}}
{{- end -}}
{{- if eq $tag "latest" -}}
{{- fail (printf "the pin for %q is \"latest\" — a mutable tag can be repointed after validation, which gate G8 rejects" $want) -}}
{{- end -}}
{{- with $root.Values.image.registry }}{{ . }}/{{ end }}{{ $want }}:{{ $tag }}
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
