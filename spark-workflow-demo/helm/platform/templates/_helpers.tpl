{{/* Common labels */}}
{{- define "spark-platform.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: spark-workflow-demo
{{- end }}

{{/* Selector labels for a component */}}
{{- define "spark-platform.selectorLabels" -}}
app.kubernetes.io/name: {{ . }}
app.kubernetes.io/instance: spark-platform
{{- end }}

{{/*
Shared OIDC config for the per-route SecurityPolicies. One policy per route
(not one for both) because redirectURL must match the host the flow starts
on: Envoy's oauth2 filter stores the CSRF/session cookies on the originating
host, so a callback on any other host fails with "OAuth flow failed".
*/}}
{{- define "spark-platform.oidcCommon" -}}
provider:
  issuer: https://{{ .Values.hosts.keycloak }}/realms/{{ .Values.keycloak.realm }}
  # Back-channel (token redeem, JWKS) directly against the in-cluster
  # Keycloak service: the public hostname resolves to the NLB, and
  # hairpinning through an internet-facing NLB from the Envoy pods
  # fails (503 after login). Front-channel URLs stay public.
  backendRefs:
    - name: keycloak
      port: 8080
  tokenEndpoint: http://keycloak.{{ .Release.Namespace }}.svc.cluster.local:8080/realms/{{ .Values.keycloak.realm }}/protocol/openid-connect/token
  authorizationEndpoint: https://{{ .Values.hosts.keycloak }}/realms/{{ .Values.keycloak.realm }}/protocol/openid-connect/auth
clientID: {{ .Values.keycloak.clientId }}
clientSecret:
  name: oauth2-proxy
logoutPath: /oauth2/sign_out
forwardAccessToken: true
{{- end }}

