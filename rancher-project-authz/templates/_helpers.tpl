{{/*
Build a stable, RFC-1123-valid resource name from an arbitrary label.
Sanitises separators and appends a short deterministic hash so that two
bindings that differ only in a truncated tail can't collide.
Usage: {{ include "authz.bindingName" "prtb-p-devtest-dev-team-project-member" }}
*/}}
{{- define "authz.bindingName" -}}
{{- $raw := . -}}
{{- $hash := sha1sum $raw | trunc 8 -}}
{{- $slug := $raw | lower | replace "_" "-" | replace ":" "-" | replace "/" "-" | replace "." "-" | replace " " "-" | trunc 45 | trimSuffix "-" -}}
{{- printf "%s-%s" $slug $hash -}}
{{- end -}}

{{/*
Render a principal line (groupPrincipalName or userPrincipalName) for a binding.
Takes a dict: { binding, groupPrefix, userPrefix }.
*/}}
{{- define "authz.principal" -}}
{{- $b := .binding -}}
{{- if $b.group -}}
groupPrincipalName: {{ printf "%s%s" .groupPrefix $b.group | quote }}
{{- else if $b.user -}}
userPrincipalName: {{ printf "%s%s" .userPrefix $b.user | quote }}
{{- else -}}
{{- fail (printf "binding must set either 'group' or 'user': %v" $b) -}}
{{- end -}}
{{- end -}}

{{/*
Subject slug for naming: the group or user name.
*/}}
{{- define "authz.subject" -}}
{{- $b := . -}}
{{- if $b.group -}}{{ $b.group }}{{- else -}}{{ $b.user }}{{- end -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "authz.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Name }}
app.kubernetes.io/part-of: rancher-project-authz
{{- end -}}

{{/*
Compute the effective project bindings for a project:
  - auto-generated owner/member/viewer group bindings (Convention over Config),
    derived from the project's groupBase (defaults to its name)
  - plus any explicit bindings listed under the project
Returns a JSON array; parse with `fromJsonArray`.
Input: dict { project, values }.
*/}}
{{- define "authz.effectiveBindings" -}}
{{- $p := .project -}}
{{- $v := .values -}}
{{- $result := list -}}
{{- $ag := $v.autoGroups | default dict -}}
{{- if $ag.enabled -}}
{{- $prefix := $ag.groupPrefix | default "" -}}
{{- $base := $p.groupBase | default $p.name -}}
{{- $sep := $ag.separator | default "_" -}}
{{- range $tier, $role := ($ag.roles | default dict) -}}
{{- $result = append $result (dict "group" (printf "%s%s%s%s" $prefix $base $sep $tier) "role" $role "tier" $tier) -}}
{{- end -}}
{{- end -}}
{{- range $b := ($p.bindings | default list) -}}
{{- $result = append $result $b -}}
{{- end -}}
{{- $result | toJson -}}
{{- end -}}

{{/*
Return the list of projects to render, honouring the optional `onlyProject`
value. When onlyProject is set, only the project whose name matches is kept.
Returns a JSON array; parse with `mustFromJson`.
*/}}
{{- define "authz.selectedProjects" -}}
{{- $only := .Values.onlyProject | default "" -}}
{{- $result := list -}}
{{- range $p := (.Values.projects | default list) -}}
{{- if or (eq $only "") (eq $only $p.name) -}}
{{- $result = append $result $p -}}
{{- end -}}
{{- end -}}
{{- $result | toJson -}}
{{- end -}}

{{/*
Booleans for the target switch.
*/}}
{{- define "authz.renderManagement" -}}
{{- if or (eq .Values.target "management") (eq .Values.target "all") -}}true{{- end -}}
{{- end -}}
{{- define "authz.renderWorkload" -}}
{{- if or (eq .Values.target "workload") (eq .Values.target "all") -}}true{{- end -}}
{{- end -}}
