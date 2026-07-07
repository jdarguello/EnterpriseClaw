---
applyTo: "gitops/**"
description: EnterpriseClaw GitOps / Argo CD layer — public framework vs private tenant repo.
---

# GitOps / Argo work (`gitops/`)

You own the declarative Kubernetes/Argo layer that Argo CD reconciles onto the cluster.

## The two-repo model — internalize this before every change
Getting a change into the **right repo** is the single most important judgment call here.

- **PUBLIC repo** = the `gitops/` tree in *this* codebase
  (https://github.com/jdarguello/EnterpriseClaw). It holds the **global framework
  definitions every tenant builds on**: Helm charts/values under `gitops/helm/**`, config
  overlays under `gitops/config/**`, Argo Workflow templates under `gitops/templates/**`,
  the agentic stack under `gitops/agentic/**`. It must stay **tenant-agnostic**. (Existing
  hardcoded sandbox IDs like `grupobancolombia-innersource` are intentional throwaway data
  — don't re-flag them, but don't add new ones; parameterize instead.)
- **PRIVATE repo** = the user's own config repo (the CLI vendors a gitignored clone at
  `cli/gitops-config/`). It is the Argo CD **app-of-apps root** (`main.yaml`) and holds
  **per-tenant data**: live infra outputs (ALB role ARN, cert ARN, hosted-zone IDs,
  nodegroup labels), the AWS-specific `ClusterSecretStore`/External-Secrets wiring, and the
  multi-source overlays that **remote-reference the public repo at `?ref=main`** and patch
  it per tenant (Argo `$values` for Helm; Kustomize patches for config).

**Rule of thumb:** global/default/shared → public `gitops/`; tenant-specific values, infra
IDs, cloud-specific secret plumbing → private repo (or the CLI's patching logic that
generates it — `kube-tools/bootstrap.nu`, owned by the cli area). When a change needs both,
**state clearly which piece goes where.**

## App-of-apps structure
The private `main.yaml` renders children that overlay the public repo: an ApplicationSet
`helm` (globs `helm/*`), a single atomic Application `helm-istio` (deliberately NOT an
ApplicationSet), an ApplicationSet `configs` (globs `config/*`), and an `agentic`
ApplicationSet (globs `gitops/agentic/**` → agents / mcps / mcp-gateway / llm-gateway). New
components usually land where an existing ApplicationSet globs them. Secrets resolve at
runtime via External-Secrets + an AWS Secrets Manager `ClusterSecretStore`.

## Conventions & known fragilities
- Service mesh is **Istio ambient** — **ztunnel** (L4 mTLS/SPIFFE) + **agentgateway** as
  the L7 waypoint. Respect security-shaped node placement (tainted `role=frontend` public
  nodegroup for edge workloads; private nodegroups for controllers/backends).
- **No sync-wave annotations despite real dependencies** (ClusterSecretStore →
  ExternalSecrets, istiod → gateways) — a known cause of flaky installs/destroys. When you
  add dependent resources, consider `argocd.argoproj.io/sync-wave` ordering and call it out.
- **ApplicationSet child-name collisions cascade-prune** — an app owned by two controllers
  deadlocks on the `resources-finalizer` and wedges in `Terminating` (e.g. the broker
  installer MUST be `session-broker-bootstrap`, not `session-broker`).
- **Gateway-API CRDs** ship as a dedicated GitOps Application at sync-wave `-1` — Istio
  ambient does NOT ship the `gateway.networking.k8s.io` CRDs by default. Istio stays the
  sole owner of those CRDs; the `agentgateway-crds` chart ships only `agentgateway.dev` CRDs.
- Validate YAML you write (`kubectl --dry-run=client`, `kustomize build`, `helm template`).

## Constraints
- **Never reproduce secret values** — reference External-Secrets keys/fields by name only.
- Don't put tenant-specific data in the public repo, or global defaults only in the private
  repo. `cli/gitops-config/` (the gitignored private clone) is a separate history — flag
  private-repo changes so they're reconciled separately.
- Stay in your lane: CLI patching (`kube-tools/bootstrap.nu`) → cli area; Terraform → infra
  area; container images → actions area. For each change, tag it **public vs private**.
