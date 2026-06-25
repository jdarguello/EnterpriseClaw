# kagent trio — install & versions

Verified 2026-06-24 against kagent **v0.9.9** / agentgateway **v1.3.1**. Pre-1.0; re-verify on later releases.

## OCI chart / image refs

| Artifact | Ref | Notes |
|---|---|---|
| kagent CRDs chart | `oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds` | install **first** |
| kagent chart | `oci://ghcr.io/kagent-dev/kagent/helm/kagent` | bundles **kmcp** (≥0.7) + UI + tools + sample agents |
| kagent images | registry `cr.kagent.dev` (chart `registry:` default) | app/image tag tracks git `vX.Y.Z` |
| declarative-agent runtime | `cr.kagent.dev/kagent-dev/kagent/app@sha256:…` | the pod each `Agent` (type Declarative) runs. **LARGE** — first agent triggered a **~24 min** pull on the dry-run VM (one-time, then cached). Budget for it; pre-pull on each node if impatient. |
| agentgateway standalone | `ghcr.io/agentgateway/agentgateway:v1.3.1` | **`v` prefix required** (`1.3.1` 404s); entrypoint `/app/agentgateway`, run `-f <config>` |
| agentgateway CRDs chart | `oci://cr.agentgateway.dev/charts/agentgateway-crds` | ships ONLY `agentgateway.dev` CRDs (Backend/Parameters/Policy) — **NOT** `gateway.networking.k8s.io` |
| agentgateway chart | `oci://cr.agentgateway.dev/charts/agentgateway` | the **control plane** (controller + xDS :9978); provisions L7 proxies from Gateway CRs |

Chart registry/version: **`cr.agentgateway.dev/charts/{agentgateway,agentgateway-crds}` @ `1.3.1`** (anonymous OCI pull — no creds, like public ghcr; the in-repo `Chart.yaml` `0.0.2` is a dev placeholder, real version injected at release). 1.3.x is the line that pairs with **kagent 0.9.9** (a newer agentgateway 2.2.x line exists — do not jump to it without re-checking kagent compat). Default install namespace: **`kagent`** for the kagent trio; **`agentgateway-system`** for the agentgateway control plane.

## agentgateway Helm chart = a Gateway-API control plane (NOT "standalone vs Istio")

The `agentgateway` chart (v1.3.1, chart 0.0.2) is **kgateway-derived**: a controller + xDS gRPC server (`:9978`) that watches `Gateway`/`HTTPRoute` CRs (`gatewayClassName: agentgateway`) and provisions agentgateway **data-plane** proxies. So the **Kubernetes Gateway API is its config API and is ALWAYS used** — it is *not* an alternative to Istio, and you can't "turn Gateway API off" via values. Verified template set: `deployment.yaml` (the `controller` container), `service.yaml`, `serviceaccount.yaml`, `role.yaml`, hpa/vpa/pdb, `monitoring.yaml`. No GatewayClass template (the controller registers the built-in `agentgateway` class itself).

**"Use Istio" is a first-class values block, and it means mesh-integration (the waypoint model), not replacing Gateway API:**
```yaml
istio:
  autoEnabled: true        # every built-in-class (agentgateway) gateway joins the Istio mesh by default
  namespace: istio-system  # istiod location; caAddress defaults to https://istiod.istio-system.svc:15012
  # revision / clusterId / network: for revisioned or multi-cluster istiod
```
`autoEnabled: true` → the provisioned proxies get SPIFFE/mTLS identities from istiod (the workload rail) while agentgateway enforces the user JWT at L7 — the CLAUDE.md §2.2 waypoint. A specific gateway can opt out with `AgentgatewayParameters spec.istio.enabled=false`. EnterpriseClaw set: [gitops/helm/agents/agentgateway/](../../../../gitops/helm/agents/agentgateway/).

**Hard prerequisites to deploy this chart at all:** (1) the **`gateway.networking.k8s.io` CRDs** must exist (the controller's informers need them) — they come from **Istio** (this chart does *not* ship them); (2) for *meshed* gateways (`autoEnabled: true`), **istiod** must be reachable. On a bare cluster with neither (e.g. the dry-run VM), install Istio (or at least the Gateway-API CRDs) first, or the controller can't function. Other knobs: `controller.{replicaCount,logLevel}`, `resources` (GOMEMLIMIT/GOMAXPROCS derive from `limits.memory`/`limits.cpu` via the downward API — always set explicit limits), `inferenceExtension.enabled`, `monitoring.enabled` (needs Prometheus-Operator CRDs).

## Resolving the real chart version (the pagination trap)

The git tag (`v0.9.9`) is the **app/image** version. The **chart** version is published independently per-chart on ghcr and must be resolved from the registry. The `tags/list` API **paginates** — a naïve `curl|grep|tail` shows a stale `0.7.x` as "latest". Page properly:

```python
import json, urllib.request, re
def tags(repo):
    tok = json.load(urllib.request.urlopen(
        f"https://ghcr.io/token?scope=repository:{repo}:pull"))["token"]
    url, out = f"https://ghcr.io/v2/{repo}/tags/list?n=1000", []
    while url:
        r = urllib.request.urlopen(urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"}))
        out += json.load(r).get("tags", [])
        link = r.headers.get("Link")
        url = ("https://ghcr.io" + re.search(r'<([^>]+)>', link).group(1)) if (link and 'rel="next"' in link) else None
    return out
# repos: kagent-dev/kagent/helm/kagent , kagent-dev/kagent/helm/kagent-crds
# sort stable tags by version tuple; both were 0.9.9 on 2026-06-24.
```

Git tags (sanity-check the app version): `git ls-remote --tags https://github.com/kagent-dev/kagent`.

## Trimmed `values.yaml` for the kagent chart (small-cluster / dry-run)

The chart is heavy by default: a **bundled Postgres** (250m/256Mi), the **UI** (≤1Gi), **kagent-tools**, **kmcp**, **10 sample agents** (~128Mi each → ~1.3Gi if left on), and MCP tool servers (`grafana-mcp`, `querydoc`). All keys below are **VERIFIED** in `helm/kagent/values.yaml@v0.9.9`.

```yaml
database:
  postgres:
    bundled:
      enabled: true           # REQUIRED — do NOT disable without an external DB (see gotcha below).
                              # ~256Mi pod + a PVC (needs a default StorageClass). Trim its resources if needed.
ui:
  replicas: 0                 # drop the dashboard Deployment (no documented `ui.enabled`; replicas:0 works)
kmcp:
  enabled: false              # turn on only when you need on-cluster MCPServer CRDs
kagent-tools:
  enabled: false              # built-in tool server; off unless the agent uses it
grafana-mcp: { enabled: false }
querydoc:   { enabled: false }   # also wants an OpenAI key
controller:
  replicas: 1
  watchNamespaces: ["kagent"]    # scope the watch (less work + blast radius); CRs must live here
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits:   { cpu: 1,   memory: 512Mi }   # default limit is cpu:2/mem:512Mi
rbac:
  namespaces: ["kagent"]         # Role+RoleBinding per-ns instead of cluster-scoped ClusterRole
# all 10 bundled sample agents OFF (exact keys, verbatim from values.yaml):
k8s-agent:            { enabled: false }
kgateway-agent:       { enabled: false }
istio-agent:          { enabled: false }
promql-agent:         { enabled: false }
observability-agent:  { enabled: false }
argo-rollouts-agent:  { enabled: false }
helm-agent:           { enabled: false }
cilium-policy-agent:  { enabled: false }
cilium-manager-agent: { enabled: false }
cilium-debug-agent:   { enabled: false }
```

Notes:
- **A database is MANDATORY (gotcha, verified the hard way 2026-06-24 on v0.9.9).** `controller-deployment.yaml` hard-fails at `helm template` time with *"No database connection configured"* unless one of: `database.postgres.bundled.enabled: true` (default), `database.postgres.url`, or `database.postgres.urlFile`. There is **no SQLite / DB-less mode**. So `bundled.enabled: false` is only safe when paired with an external Postgres URL — disabling it alone makes the Argo app go `Unknown`/`ComparisonError` and nothing deploys. On a small cluster, keep bundled on (~256Mi + a PVC) unless you have an external PG.
- The chart **always** renders a default `ModelConfig` from `providers.default` (→ Secret `kagent-openai`/`OPENAI_API_KEY`). It does **not** crashloop the controller if that Secret is absent — only an *agent using it* fails at call time. Author your **own** `ModelConfig` and reference it from your Agent; ignore the default. (`providers.openAI.baseUrl` is **not** a values key — set `baseUrl` on your own ModelConfig CR.)
- Helm silently ignores unknown values keys, so a mistyped disable-key leaves that component **on**. Verify against the pinned `values.yaml`, don't trust inferred names.

## controller.auth.mode (inbound identity)

```yaml
controller:
  auth:
    mode: unsecure        # default: X-User-Id header, else admin@kagent.dev
    # mode: trusted-proxy # trusts a JWT in the Authorization header (set by oauth2-proxy)
    userIdClaim: ""       # JWT claim for user id (default "sub")
```

`trusted-proxy` is the inbound path for the **user JWT to the controller/A2A** (paired with the `oauth2-proxy` subchart). This is *distinct* from outbound MCP-tool propagation (see `jwt-propagation.md`). `controller.mcpEgressPlaintext: true` rewrites RemoteMCPServer `https→http` for plaintext egress to a TLS-originating proxy.

## Argo CD delivery (EnterpriseClaw)

Express the three installs as sync-waved `Application`s: **CRDs (wave 0) → controller/agentgateway (wave 1) → CRs (wave 2)**. CRs (`Agent`/`ModelConfig`/`RemoteMCPServer`) fail until the CRDs exist, so the wave ordering (parent app-of-apps waits for each wave Healthy) avoids flaky first syncs. Working set: [gitops/dry-run/](../../../gitops/dry-run/).
