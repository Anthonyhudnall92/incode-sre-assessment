{{- define "uptime.labels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
{{- end }}

{{- define "uptime.image" -}}
{{- $repo := required "image.repository is required" .Values.image.repository -}}
{{- $digest := required "image.digest is required" .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) -}}
{{- fail "image.digest must be sha256:<64 hex>; images are pinned by digest, never by tag" -}}
{{- end -}}
{{ $repo }}@{{ $digest }}
{{- end }}
