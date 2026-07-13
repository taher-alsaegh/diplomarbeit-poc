# rancher-project-authz

A Helm chart that describes the **complete authorization layout of a Rancher
cluster in one `values.yaml`** and renders it into Rancher CRDs and matching
ArgoCD AppProjects. Role bindings are driven by **IdP groups** (Keycloak OIDC or
Active Directory) instead of individual users, so access is granted by group
membership in the identity provider — add a user to a group in Keycloak and they
gain the mapped Rancher rights automatically, with nothing changed in Rancher.

## What it generates

From a single values file the chart produces:

- **Projects** (`management.cattle.io/v3 Project`) — one per tenant boundary
- **Namespaces** joined to their project via the `field.cattle.io/projectId` annotation
- **ProjectRoleTemplateBindings (PRTB)** — group/user → role on a project (`project-owner`, `project-member`, `read-only`, …)
- **ClusterRoleTemplateBindings (CRTB)** — group/user → cluster-level role (`cluster-owner`, `cluster-member`)
- **GlobalRoleBindings (GRB)** — group/user → global Rancher role (`admin`, …)
- **ArgoCD AppProjects** — one per Rancher project, scoped to that project's namespaces

## The two-cluster split (important)

Rancher's management CRDs (`Project`, `PRTB`, `CRTB`, `GRB`) live in the Rancher
**management ("local") cluster**. The actual project **namespaces** live in the
**downstream cluster**. A Helm release only ever targets one kube-context, so the
chart has a `target` switch:

| `target`     | renders                                            | apply against            |
|--------------|----------------------------------------------------|--------------------------|
| `management` | Project, PRTB, CRTB, GRB                            | Rancher local cluster    |
| `workload`   | Namespaces, ArgoCD AppProjects                     | downstream cluster       |
| `all`        | everything                                         | single-cluster demo only |

## Install

Single-cluster demo (everything on the Rancher local cluster):

```bash
helm upgrade --install authz ./rancher-project-authz \
  --set target=all
```

Real multi-cluster setup — install twice with the matching context:

```bash
# management objects into the Rancher local cluster
helm upgrade --install authz-mgmt ./rancher-project-authz \
  --kube-context rancher-local \
  --set target=management

# namespaces + argocd appprojects into the downstream cluster
helm upgrade --install authz-workload ./rancher-project-authz \
  --kube-context k3d-downstream-01 \
  --set target=workload
```

Preview without applying:

```bash
helm template authz ./rancher-project-authz | less
```

## Access model: three groups per project

The thesis uses one AD group per access tier, derived automatically from each
project's base name (`autoGroups`). No per-user assignment, no overlapping
groups, no precedence conflicts — one group, one role, one purpose:

| AD group | Rancher role | ArgoCD rights on `<appproject>/*` |
|----------|--------------|------------------------------------|
| `<base>_owner` | `project-owner` | full: get, sync, action, create, update, override, delete, exec |
| `<base>_member` | `project-member` | get, sync, action, logs (see + deploy) |
| `<base>_viewer` | `read-only` | get, logs (view only) |

You declare only the project and its `groupBase`; the chart generates all six
bindings (3 in Rancher, 3 in ArgoCD). The `autoGroups.roles` map (tier → Rancher
role) and `argocd.roleActions` (Rancher role → ArgoCD actions) are the two
explicit, auditable translation layers between the AD naming convention and each
system's RBAC.

## Values reference

| Key | Description |
|-----|-------------|
| `target` | `management`, `workload`, or `all` |
| `clusterId` | Rancher cluster ID (e.g. `c-kg5d6`); namespace for management CRDs |
| `clusterName` | Cluster name (usually equals `clusterId`) |
| `groupPrincipalPrefix` | Principal prefix for Rancher, e.g. `keycloakoidc_group://` or `activedirectory_group://` |
| `userPrincipalPrefix` | Principal prefix for Rancher users |
| `autoGroups.enabled` | Derive owner/member/viewer groups per project |
| `autoGroups.separator` | Separator between base and tier (default `_`) |
| `autoGroups.roles` | Tier → Rancher role map (`owner: project-owner`, …) |
| `argocd.enabled` | Generate ArgoCD AppProjects with mirrored roles |
| `argocd.namespace` | Namespace ArgoCD runs in |
| `argocd.server` | ArgoCD destination server (`https://kubernetes.default.svc`) |
| `argocd.groupClaimPrefix` | Prefix for the raw OIDC group name in ArgoCD (usually empty) |
| `argocd.roleActions` | Rancher role → list of ArgoCD `"resource, action"` entries |
| `clusterBindings[]` | Cluster-wide bindings: `{ group\|user, role }` |
| `globalBindings[]` | Global bindings: `{ group\|user, role }` |
| `projects[]` | Projects: `{ name, displayName, groupBase, namespaces[], bindings[]?, argocd.enabled? }` |

Bindings take **either** `group` **or** `user`; group is the intended path.
The Rancher prefix is prepended automatically, so you write `devtest_owner`, not
`keycloakoidc_group://devtest_owner`.

## Example

```yaml
target: all
clusterId: c-kg5d6
groupPrincipalPrefix: "keycloakoidc_group://"

autoGroups:
  enabled: true
  roles:
    owner: project-owner
    member: project-member
    viewer: read-only

projects:
  - name: p-devtest
    displayName: "Dev Test"
    groupBase: devtest        # -> devtest_owner / devtest_member / devtest_viewer
    namespaces: [my-app]
```

This one project produces, automatically: the Rancher Project, three PRTBs
(`devtest_owner`→project-owner, `devtest_member`→project-member,
`devtest_viewer`→read-only) and a matching ArgoCD AppProject with the same three
groups as project-scoped roles.

## ArgoCD: mirroring Rancher rights

Each generated AppProject carries **project-scoped roles** derived from the same
project bindings, so a Keycloak group has equivalent rights on its AppProject as
on its Rancher project. The Rancher role is mapped to ArgoCD actions via
`argocd.roleActions` (graded by default):

| Rancher role | ArgoCD actions on `<appproject>/*` |
|--------------|-------------------------------------|
| `read-only` | `applications get`, `logs get` (view only) |
| `project-member` | `+ applications sync`, `applications action/*` (see + sync) |
| `project-owner` | `+ create/update/override/delete`, `exec create` (full) |

Two things differ from Rancher and are handled automatically:

- ArgoCD matches the **raw group name** from the OIDC `groups` claim
  (`dev-team`), not the Rancher principal prefix. Controlled by
  `argocd.groupClaimPrefix` (empty by default).
- Rights are scoped per AppProject through `proj:<appproject>:<role>` policies
  living **inside** the AppProject, so nothing in `argocd-rbac-cm` is touched.

Only **group** bindings are mirrored to ArgoCD (project roles bind OIDC groups);
`user` bindings are applied in Rancher only.

## Verify

```bash
# management cluster
kubectl get projects.management.cattle.io -n c-kg5d6
kubectl get projectroletemplatebindings.management.cattle.io -n c-kg5d6
kubectl get clusterroletemplatebindings.management.cattle.io -n c-kg5d6

# downstream cluster
kubectl get ns -l field.cattle.io/projectId
```

## Notes

- Switching the identity provider only changes `groupPrincipalPrefix` /
  `userPrincipalPrefix` — the rest of the model is provider-agnostic.
- Client secrets and IdP configuration are **not** part of this chart; keep them
  in ExternalSecrets / Vault. This chart only manages the authorization mapping.
- Deploy it through ArgoCD (App-of-Apps) so the authorization layout itself is
  GitOps-managed and auditable.
