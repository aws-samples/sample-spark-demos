{{/* Common labels */}}
{{- define "spark-api.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: spark-api-demo
{{- end }}

{{/* Selector labels for a service */}}
{{- define "spark-api.selectorLabels" -}}
app.kubernetes.io/name: {{ . }}
app.kubernetes.io/instance: spark-api
{{- end }}
