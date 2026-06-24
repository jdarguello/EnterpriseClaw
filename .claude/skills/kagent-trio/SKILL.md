---
name: kagent-trio
description: >-
  Authoritative, version-pinned reference for the kagent trio — kagent (Agent + ModelConfig
  CRDs, A2A server), kmcp (MCPServer CRD that runs MCP servers on-cluster), and agentgateway
  (the L7 data plane: A2A routing, MCP federation, JWT/auth — as an Istio ambient waypoint or
  standalone). Use when installing, pinning versions for, configuring, or debugging any of
  these on Kubernetes/Argo CD; when authoring their CRDs or Helm values; or when working on
  JWT / two-identity propagation (user JWT + workload SPIFFE) through them.
---

# kagent trio

The **agentic stack for EnterpriseClaw** (decided 2026-06-24, see [CLAUDE.md](../../CLAUDE.md) §2.2). Three CNCF-Sandbox, **pre-1.0** projects pinned as one compatible *set*:

| Piece | What it is | CRDs / artifacts |
|---|---|---|
| **kagent** | the agent runtime — declarative agents + an A2A server | `Agent`, `ModelConfig` (`kagent.dev/v1alpha2`) |
| **kmcp** | controller that *runs* MCP servers on-cluster | `MCPServer` (bundled inside the kagent chart ≥0.7) |
| **agentgateway** | the L7 data plane *between* the pieces — A2A routing, MCP federation/multiplex, JWT validation + tool-level authz | standalone `config.yaml` **or** Gateway-API `Gateway` (`gatewayClassName: agentgateway`) / `AgentgatewayPolicy` |

In the EnterpriseClaw architecture: **agentgateway is the Istio ambient L7 waypoint** (owns user-JWT validation + MCP/tool authz + fronts Bedrock as the LLM gateway); **ztunnel** is the L4 mTLS/SPIFFE substrate. *The model is not the security boundary — the mesh is.*

> **Knowledge is dated.** Everything here was verified **2026-06-24** against **kagent v0.9.9** and **agentgateway v1.3.1** from source. These are pre-1.0 with real API churn (e.g. ToolServer→kmcp, Cedar→CEL, v1alpha1→v1alpha2). Re-verify versions/fields before trusting this on a later release.

## Read this first — the 6 gotchas that will bite you

1. **Chart version ≠ app/git version, and the OCI tag list is paginated.** The git release tag (`v0.9.9`) is the *app/image* version; the Helm *chart* is published per-chart on ghcr and you must resolve its tag from the registry. The ghcr `tags/list` API **paginates** — a naïve `curl | grep | tail` will show `0.7.x` as "latest" and be wrong. Page through with `?n=1000` + the `Link` header. (As of 2026-06-24 both charts happen to be at `0.9.9`, matching the app — but *verify*, don't assume.) → `reference/install.md`.
2. **`ModelConfig` serves two API versions with different field names.** `v1alpha1` uses `apiKeySecretRef`; **`v1alpha2`** (what the `Agent` CR uses) uses **`apiKeySecret` + `apiKeySecretKey`**, and adds `apiKeyPassthrough` + `openAI.tokenExchange` + a first-class `bedrock` block. Author **v1alpha2**. → `reference/crds.md`.
3. **agentgateway *strips* the validated credential before forwarding to the MCP upstream — by default.** To forward the user bearer you must opt in with `backendAuth: passthrough: {}`. This is *the* lever for JWT propagation. → `reference/agentgateway.md`.
4. **kagent has no documented *dynamic* forward of the incoming A2A bearer to MCP tool calls.** `RemoteMCPServer.headersFrom` is **static** (from a Secret), not pass-through. The dynamic path is agentgateway's `passthrough` (gotcha 3). `ModelConfig.apiKeyPassthrough`/`tokenExchange` are the *model* hop, a **separate identity rail** — don't conflate. → `reference/jwt-propagation.md`.
5. **The kagent chart is heavy by default** — bundled Postgres + UI + 10 sample agents + tool servers. On a small cluster it must be trimmed hard, or pods pend / crashloop. Exact verified disable-keys in → `reference/install.md`.
6. **agentgateway has two distinct config surfaces.** Standalone YAML (`binds/listeners/routes/policies`) is **not** the same shape as the Kubernetes `AgentgatewayPolicy` CRD (`spec.traffic.jwtAuthentication`, `spec.backend.mcp.authorization`). Don't mix them. And the live `examples/*/config.yaml` use **CEL** rules even where READMEs still show old **Cedar** `permit(...)`. Trust the config.yaml.

## Canonical install (Helm / OCI)

```bash
# CRDs first, then controller. Both OCI charts; namespace `kagent`.
helm install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --version <resolved-chart-ver> --namespace kagent --create-namespace
helm install kagent      oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --version <resolved-chart-ver> --namespace kagent -f values-trimmed.yaml
# agentgateway: standalone Deployment of ghcr.io/agentgateway/agentgateway:v1.3.1 -f config.yaml,
# OR the Gateway-API/Istio-waypoint chart oci://cr.agentgateway.dev/charts/agentgateway.
```

In EnterpriseClaw these become **Argo CD `Application`s** (multi-source, sync-waved: CRDs → controller → CRs). See [gitops/dry-run/](../../../gitops/dry-run/) for the working dry-run set.

## Reference files

- **`reference/install.md`** — OCI chart refs, version-resolution (pagination) recipe, the verified trimmed `values.yaml` (disable Postgres/UI/sample-agents/tool-servers), footprint math, namespace scoping (`rbac.namespaces`/`controller.watchNamespaces`), `controller.auth.mode`.
- **`reference/crds.md`** — verified field tables + minimal examples for `Agent`, `ModelConfig` (v1alpha2), `RemoteMCPServer`, and the kmcp `MCPServer`.
- **`reference/agentgateway.md`** — standalone vs waypoint; the `binds/listeners/routes/backends` schema; `jwtAuth` (JWKS) + `backendAuth: passthrough` + `mcpAuthorization` (CEL); MCP transport keyword (`mcp: { host: … }`); image/ports/probe.
- **`reference/jwt-propagation.md`** — the riskiest-unknown, the kind+echo-MCP dry-run rig, the fallback ladder, findings, and the two identity rails (user JWT vs workload SPIFFE; MCP hop vs model hop).

## When NOT to use this

For the broader EnterpriseClaw architecture (Slack→Argo→Crossplane spine, Session-Broker, build phases P0–P3), read [CLAUDE.md](../../CLAUDE.md) §2.2 — that is the architecture-of-record; this skill is the *implementation* reference for the three components.
