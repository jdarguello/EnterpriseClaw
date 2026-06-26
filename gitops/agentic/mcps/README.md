# Agentic MCP servers

The tool servers the agents call. Each is GitHub's official **github-mcp-server**, run on-cluster by
**kmcp** (`MCPServer`, `kagent.dev/v1alpha1`): the stdio binary is wrapped in a sidecar HTTP gateway
and exposed as Service `<name>:3000` serving MCP at `/mcp` (StreamableHTTP).

They are **toolset-scoped** so the privilege tiers split at the MCP/route level — no per-tool CEL
needed (the granularity the dry-run proved, [§2.2](../../.claude/CLAUDE.md)):

| MCPServer | `GITHUB_TOOLSETS` | Access | Boundary |
|---|---|---|---|
| `github-issues` | `issues` | **auth** baseline (`agent-user`) | agentgateway route requires `issue:create` (client `issue-tracker`) |
| `infra-provisioning` | `repos,pull_requests` | **auth** senior (`senior-engineer`) | agentgateway route requires `db:provision:dev` (client `infra-provisioner`) |
| `github-readonly` | `issues,pull_requests` (`--read-only`) | **unauth** (no JWT) | the tool surface itself — `--read-only` registers zero write tools; no gateway route |

The two **auth** MCPs are gated one hop in front, in [../mcp-gateway/](../mcp-gateway/) (the agentgateway
`Gateway` + `HTTPRoute` + `AgentgatewayPolicy` that validate the Keycloak JWT and claim-gate each route).
`github-readonly` is **deliberately not** behind a route: the unauthenticated path carries no user JWT to
validate, so its boundary is the **physically read-only** github-mcp-server (`--read-only`) plus its
read-scoped token — reached directly (`kind: MCPServer`) by the [`github-reader`](../agents/github-reader/)
agent on the workload (ztunnel SPIFFE) rail. A prompt-injected reader still has no write tool to call, and
no JWT to pass the Strict gates above. *The model is not the security boundary — the tool surface + mesh are.*

## Prereqs — GitHub token Secrets (not committed)

Two Secrets in ns `kagent`, each with key `GITHUB_PERSONAL_ACCESS_TOKEN`, injected via kmcp
`secretRefs` → `envFrom`:

- **`github-creds`** (read/write) — `github-issues` + `infra-provisioning` `envFrom` it. A PAT or a
  GitHub-App installation token from the [create-github-app-token](../../../actions/) mint. Per §2.2 the
  **user JWT stops at the gateway** — GitHub-side auth is this bot/App token; human attribution lives in
  the Argo Workflow archive + agentgateway trace.
- **`github-readonly-creds`** (READ-scoped) — `github-readonly` `envFrom` it. **Keep it separate and
  least-privilege**: because the unauthenticated reader has no user identity, this token *is* the
  anonymous blast radius — it can read exactly what the token can see, so scope it to public/specific
  repos with read-only permissions. Defense in depth with the MCP's `--read-only` flag.

Until each Secret exists its pod(s) stay `NotReady` (envFrom of a missing Secret). The authenticated
authz gating in front is still fully testable regardless (the gateway rejects/allows *before* contacting
its upstream).
