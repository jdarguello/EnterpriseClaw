# agentgateway — config reference

Verified 2026-06-24 against **v1.3.1** (config.rs, examples/*, Dockerfile). Pre-1.0.

## Two deployment modes — pick by purpose

| Mode | How | Use for |
|---|---|---|
| **Standalone** | plain Deployment of `ghcr.io/agentgateway/agentgateway:v1.3.1`, `-f config.yaml` from a ConfigMap. No Istio, no Gateway-API. | dry-runs, isolating the L7 hop without mesh confounders |
| **Kubernetes / waypoint** | Helm `oci://cr.agentgateway.dev/charts/agentgateway`; Gateway-API `Gateway` w/ `gatewayClassName: agentgateway`; policy via the **`AgentgatewayPolicy`** CRD (`spec.traffic.jwtAuthentication`, `spec.backend.mcp.authorization`). As an **Istio ambient L7 waypoint** in EnterpriseClaw. | production / the demo |

> The standalone YAML and the `AgentgatewayPolicy` CRD are **different config surfaces** — don't copy fields between them.

## Standalone container

```yaml
containers:
- name: agentgateway
  image: ghcr.io/agentgateway/agentgateway:v1.3.1   # NB: 'v' prefix required
  args: ["-f", "/etc/agentgateway/config.yaml"]
  ports:
  - { name: data,      containerPort: 3000 }    # = binds[].port in the config
  - { name: readiness, containerPort: 15021 }   # 0.0.0.0
  - { name: metrics,   containerPort: 15020 }    # 0.0.0.0
  readinessProbe:
    httpGet: { path: /healthz/ready, port: 15021 }
  volumeMounts:
  - { name: config, mountPath: /etc/agentgateway, readOnly: true }
```
Other ports: admin/config_dump = `localhost:15000` (localhost-bound → not probe-reachable unless `ADMIN_ADDR` overridden). Env overrides: `ADMIN_ADDR`, `STATS_ADDR`, `READINESS_ADDR`. `jwtAuth.jwks.file` paths are relative to the **binary's CWD (`/`)**, not the config file — prefer `jwks.url` in-cluster, or mount at an absolute path.

## Config schema (standalone)

```
binds:                       # one per listening port
- port: <int>
  listeners:
  - routes:
    - policies: { … }        # per-route: cors, jwtAuth, backendAuth, mcpAuthorization, a2a, …
      backends: [ … ]        # mcp{targets}, or a host for A2A
```

### MCP route with JWT validation + passthrough + tool authz (the propagation path)

```yaml
# yaml-language-server: $schema=https://agentgateway.dev/schema/config
binds:
- port: 3000
  listeners:
  - routes:
    - policies:
        cors:
          allowOrigins: ["*"]
          allowHeaders: ["mcp-protocol-version", "content-type", "mcp-session-id"]
          exposeHeaders: ["Mcp-Session-Id"]
        jwtAuth:                                   # validate the USER JWT
          issuer: "https://keycloak.example/realms/REALM"
          audiences: ["the-agents"]
          jwks: { url: "https://keycloak.example/realms/REALM/protocol/openid-connect/certs" }
        backendAuth:
          passthrough: {}                          # << FORWARD the bearer to the MCP upstream
        mcpAuthorization:                          # per-tool authz (CEL, not Cedar)
          rules:
          - 'mcp.tool.name == "echo"'                            # anyone authenticated
          - 'jwt.sub == "alice" && mcp.tool.name == "create_pr"' # claim-gated
      backends:
      - mcp:
          targets:
          - name: echo
            mcp: { host: "http://echo-mcp.kagent.svc.cluster.local:8080/mcp" }   # remote streamable-HTTP
            # stdio: { cmd: npx, args: ["@modelcontextprotocol/server-everything"] }  # alt transport
```

**Key facts:**
- `backendAuth` **strips** the credential by default; `passthrough: {}` is what forwards it. Other methods: `key` (static), `aws` (SigV4 — relevant to the **Bedrock IRSA** LLM-gateway hop), `gcp`.
- Remote streamable-HTTP MCP target keyword is **`mcp: { host: <url> }`** (not `url:`, not `streamableHttp:`). `stdio:` is the other transport.
- Authz rules are **CEL** (`mcp.tool.name`, `jwt.sub`, `jwt.claims.*`, `source.principal`) — READMEs may still show old **Cedar** `permit(...)`; trust `examples/*/config.yaml`.

### A2A route (agentgateway in front of a kagent agent)

```yaml
binds:
- port: 3000
  listeners:
  - routes:
    - policies: { a2a: {}, jwtAuth: { … } }     # mark as A2A + validate user JWT at ingress
      backends:
      - host: kagent-agent.kagent.svc.cluster.local:8080
```

## How this maps to EnterpriseClaw

agentgateway is the **ambient L7 waypoint**: validates the Keycloak JWT (JWKS), authorizes on **workload SPIFFE (`source.principal`) AND user claims (`jwt.*`)**, federates MCP with `passthrough` carrying the user bearer, and fronts **Bedrock as the LLM gateway** (its SA holds the Bedrock IRSA; `backendAuth: aws` SigV4; Guardrails at `InvokeModel`). ztunnel handles L4 mTLS/SPIFFE beneath it. See `jwt-propagation.md` and [CLAUDE.md](../../CLAUDE.md) §2.2.
