# kagent trio — install & versions

Verified 2026-06-24 against kagent **v0.9.9** / agentgateway **v1.3.1**. Pre-1.0; re-verify on later releases.

## OCI chart / image refs

| Artifact | Ref | Notes |
|---|---|---|
| kagent CRDs chart | `oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds` | install **first** |
| kagent chart | `oci://ghcr.io/kagent-dev/kagent/helm/kagent` | bundles **kmcp** (≥0.7) + UI + tools + sample agents |
| kagent images | registry `cr.kagent.dev` (chart `registry:` default) | app/image tag tracks git `vX.Y.Z` |
| agentgateway standalone | `ghcr.io/agentgateway/agentgateway:v1.3.1` | **`v` prefix required** (`1.3.1` 404s); entrypoint `/app/agentgateway`, run `-f <config>` |
| agentgateway K8s chart | `oci://cr.agentgateway.dev/charts/agentgateway` | Gateway-API; `gatewayClassName: agentgateway`; needs Gateway-API CRDs |

Default install namespace: **`kagent`**.

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
      enabled: false          # biggest single saving (no long-term memory / req-log persistence)
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
