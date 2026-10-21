{{/*
DNS-safe chart name (lowercase, dots → hyphens).
*/}}
{{- define "docling-rq.chartName" -}}
{{- $n := default .Chart.Name .Values.nameOverride | toString -}}
{{- $n | lower | replace "." "-" | trunc 53 | trimSuffix "-" -}}
{{- end }}

{{/*
Expand the name of the chart (app.kubernetes.io/name label).
*/}}
{{- define "docling-rq.name" -}}
{{- include "docling-rq.chartName" . -}}
{{- end }}

{{/*
Effective stage name: chart-level Values.stage.name overrides global.stage.name.
*/}}
{{- define "docling-rq.effectiveStageName" -}}
{{- $local := .Values.stage | default dict -}}
{{- $gst := (.Values.global | default dict).stage | default dict -}}
{{- if $local.name -}}
{{- $local.name | toString -}}
{{- else if $gst.name -}}
{{- $gst.name | toString -}}
{{- end -}}
{{- end }}

{{/*
Environment label value: stage name, else global.labels.environment, else chart labels.environment.
*/}}
{{- define "docling-rq.environmentLabel" -}}
{{- $sn := include "docling-rq.effectiveStageName" . -}}
{{- if $sn -}}
{{- $sn -}}
{{- else -}}
{{- $g := (.Values.global | default dict).labels | default dict -}}
{{- $l := .Values.labels | default dict -}}
{{- default "" (default $l.environment $g.environment) -}}
{{- end -}}
{{- end }}

{{/*
Stage suffix appended to resource names (e.g. "-dev"). Empty when no stage is set.
*/}}
{{- define "docling-rq.stageSuffix" -}}
{{- $sn := include "docling-rq.effectiveStageName" . -}}
{{- if $sn -}}
{{- printf "-%s" ($sn | lower | replace "." "-" | trunc 10 | trimSuffix "-") -}}
{{- end -}}
{{- end }}

{{/*
Base name: {Release.Name}-{chart.name}.
*/}}
{{- define "docling-rq.fullnameBase" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "docling-rq.chartName" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Fully qualified resource name: {Release.Name}-{chart.name}-{stage.name}.
*/}}
{{- define "docling-rq.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- include "docling-rq.fullnameBase" . -}}
{{- else }}
{{- $base := include "docling-rq.fullnameBase" . -}}
{{- $suffix := include "docling-rq.stageSuffix" . -}}
{{- printf "%s%s" $base $suffix | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/*
Chart label value.
*/}}
{{- define "docling-rq.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources and pod templates.
*/}}
{{- define "docling-rq.labels" -}}
helm.sh/chart: {{ include "docling-rq.chart" . }}
{{ include "docling-rq.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels for the API server Deployment and Service.
*/}}
{{- define "docling-rq.selectorLabels" -}}
app.kubernetes.io/name: {{ include "docling-rq.name" . }}
app.kubernetes.io/instance: {{ include "docling-rq.fullname" . }}
{{- end }}

{{/*
Name of the ServiceAccount to use.
*/}}
{{- define "docling-rq.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "docling-rq.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Workload namespace: Values.namespaceOverride when set, else Release.Namespace.
*/}}
{{- define "docling-rq.namespace" -}}
{{- $ns := .Values.namespaceOverride | default "" | toString | trim -}}
{{- if $ns -}}
{{- $ns -}}
{{- else -}}
{{- .Release.Namespace | default "default" -}}
{{- end -}}
{{- end }}

{{/*
Name of the Secret holding the Redis connection URL, or empty string.
Returns a non-empty value only when a secret is actually expected:
  - redisUrl.secretName is explicitly set (user-provided / ESO), OR
  - redis.auth.enabled=true (redis subchart will create the Secret).
Returns empty when auth is disabled, signalling that a plain URL should be used.
*/}}
{{- define "docling-rq.redisUrlSecretName" -}}
{{- if .Values.redisUrl.secretName -}}
{{- .Values.redisUrl.secretName -}}
{{- else -}}
{{- $redisConf := (.Values.redis | default dict) -}}
{{- $authConf := $redisConf.auth | default dict -}}
{{- if $authConf.enabled -}}
{{- $fullOverride := $redisConf.fullnameOverride | default "" -}}
{{- $nameOverride  := $redisConf.nameOverride | default "" -}}
{{- if $fullOverride -}}
{{- $fullOverride -}}
{{- else if $nameOverride -}}
{{- printf "%s-%s" .Release.Name $nameOverride -}}
{{- else -}}
{{- printf "%s-redis" .Release.Name -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Plain (unauthenticated) Redis URL derived from the subchart service name.
Used when redis.auth.enabled=false and no redisUrl.secretName is set.
Service name resolution order:
  1. redis.fullnameOverride  (explicit, verbatim)
  2. {release}-{redis.nameOverride}  (prefixed by release name)
  3. {release}-redis  (default)
*/}}
{{- define "docling-rq.redisUrlPlain" -}}
{{- $redisConf := (.Values.redis | default dict) -}}
{{- $fullOverride := $redisConf.fullnameOverride | default "" -}}
{{- $nameOverride  := $redisConf.nameOverride | default "" -}}
{{- $host := "" -}}
{{- if $fullOverride -}}
{{- $host = $fullOverride -}}
{{- else if $nameOverride -}}
{{- $host = printf "%s-%s" .Release.Name $nameOverride -}}
{{- else -}}
{{- $host = printf "%s-redis" .Release.Name -}}
{{- end -}}
{{- $port := ($redisConf.service | default dict).port | default 6379 -}}
{{- printf "redis://%s:%v" $host $port -}}
{{- end }}

{{/*
Merged container env (lowest → highest precedence): global.env, env, global.extraEnv, extraEnv.
Values containing "{{" are expanded via tpl at render time.
*/}}
{{- define "docling-rq.containerEnv" -}}
{{- $g := .Values.global | default dict -}}
{{- $envMap := dict }}
{{- range concat ($g.env | default list) ($g.extraEnv | default list) (.Values.env | default list) (.Values.extraEnv | default list) }}
{{- $out := dict "name" .name }}
{{- if .valueFrom }}
{{- $_ := set $out "valueFrom" .valueFrom }}
{{- else if and (kindIs "string" .value) (contains "{{" (.value | toString)) }}
{{- $_ := set $out "value" (tpl (.value | toString) $ | trim) }}
{{- else if not (kindIs "invalid" .value) }}
{{- $_ := set $out "value" .value }}
{{- end }}
{{- $_ := set $envMap .name $out }}
{{- end }}
{{- if $envMap }}{{ toYaml (values $envMap) }}{{ end }}
{{- end }}

{{/*
Shared docling engine env vars — identical between API server and workers.
Callers inject DOCLING_DEVICE separately since it differs between the two.
*/}}
{{- define "docling-rq.doclingEnv" -}}
- name: DOCLING_SERVE_ENG_KIND
  value: "rq"
{{- $secretName := include "docling-rq.redisUrlSecretName" . }}
- name: DOCLING_SERVE_ENG_RQ_REDIS_URL
  {{- if $secretName }}
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ .Values.redisUrl.key }}
  {{- else }}
  value: {{ include "docling-rq.redisUrlPlain" . | quote }}
  {{- end }}
- name: DOCLING_SERVE_ENG_RQ_RESULTS_TTL
  value: {{ .Values.docling.rqResultsTTL | quote }}
- name: DOCLING_SERVE_ENG_RQ_FAILURE_TTL
  value: {{ .Values.docling.rqFailureTTL | quote }}
- name: DOCLING_SERVE_MAX_DOCUMENT_TIMEOUT
  value: {{ .Values.docling.maxDocumentTimeout | quote }}
- name: DOCLING_SERVE_MAX_SYNC_WAIT
  value: {{ .Values.docling.maxSyncWait | quote }}
- name: DOCLING_PERF_PAGE_BATCH_SIZE
  value: {{ .Values.docling.perfPageBatchSize | quote }}
- name: DOCLING_PERF_ELEMENTS_BATCH_SIZE
  value: {{ .Values.docling.perfElementsBatchSize | quote }}
- name: DOCLING_SERVE_LAYOUT_BATCH_SIZE
  value: {{ .Values.docling.serveLayoutBatchSize | quote }}
- name: DOCLING_SERVE_TABLE_BATCH_SIZE
  value: {{ .Values.docling.serveTableBatchSize | quote }}
- name: DOCLING_SERVE_OCR_BATCH_SIZE
  value: {{ .Values.docling.serveOcrBatchSize | quote }}
- name: DOCLING_NUM_THREADS
  value: {{ .Values.docling.numThreads | quote }}
{{- end }}

{{/*
Shared emptyDir volumes present in every docling container.
*/}}
{{- define "docling-rq.sharedVolumes" -}}
- name: tmp
  emptyDir:
    sizeLimit: 500Mi
- name: home
  emptyDir:
    sizeLimit: 2Gi
{{- end }}

{{/*
Shared volume mounts for the main docling container.
*/}}
{{- define "docling-rq.sharedVolumeMounts" -}}
- name: tmp
  mountPath: /tmp
- name: home
  mountPath: /home/docling
{{- end }}
