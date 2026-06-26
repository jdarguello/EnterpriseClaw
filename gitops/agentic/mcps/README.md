# Agentic MCP servers

The tool servers the agents call. Each is GitHub's official **github-mcp-server**, run on-cluster by
**kmcp** (`MCPServer`, `kagent.dev/v1alpha1`): the stdio binary is wrapped in a sidecar HTTP gateway
and exposed as Service `<name>:3000` serving MCP at `/mcp` (StreamableHTTP).

They are **toolset-scoped** so the two authenticated privilege tiers split at the MCP/route level —
no per-tool CEL needed (the granularity the dry-run proved, [§2.2](../../.claude/CLAUDE.md)):

| MCPServer | `GITHUB_TOOLSETS` | Tier | Required Keycloak capability |
|---|---|---|---|
| `github-issues` | `issues` | baseline (`agent-user`) | `issue:create` (client `issue-tracker`) |
| `infra-provisioning` | `repos,pull_requests` | senior (`senior-engineer`) | `db:provision:dev` (client `infra-provisioner`) |

The **gating** is not here — it lives one hop in front, in [../mcp-gateway/](../mcp-gateway/) (the
agentgateway `Gateway` + `HTTPRoute` + `AgentgatewayPolicy` that validate the Keycloak JWT and
claim-gate each route). These MCPs are the *upstream*; the mesh decides who reaches them.

## Prereq — `github-creds` Secret (not committed)

Both pods `envFrom` a Secret **`github-creds`** in ns `kagent` carrying
`GITHUB_PERSONAL_ACCESS_TOKEN` (or a GitHub-App installation token from the
[create-github-app-token](../../../actions/) mint). Per §2.2 the **user JWT stops at the gateway** —
GitHub-side auth is this bot/App token; human attribution lives in the Argo Workflow archive +
agentgateway trace. Until the Secret exists the pods stay `NotReady`, but the authz gating in front
is still fully testable (the gateway rejects/allows *before* contacting these upstreams).
