{{/* Common labels */}}
{{- define "spark-api-platform.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: spark-api-demo
{{- end }}

{{/* Selector labels for a component */}}
{{- define "spark-api-platform.selectorLabels" -}}
app.kubernetes.io/name: {{ . }}
app.kubernetes.io/instance: spark-api-platform
{{- end }}

{{/* Tolerate + prefer the dedicated stateful node pool */}}
{{- define "spark-api-platform.statefulPlacement" -}}
tolerations:
  - key: dedicated
    operator: Equal
    value: stateful
    effect: NoSchedule
nodeSelector:
  spark-api-demo/pool: stateful
{{- end }}
