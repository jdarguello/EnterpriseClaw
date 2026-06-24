# kagent trio — CRDs (verified field reference)

Group/version **`kagent.dev/v1alpha2`** unless noted. Verified 2026-06-24 from the CRD schemas in `helm/kagent-crds/templates/*@v0.9.9` and the bundled-agent templates. Pre-1.0 — re-check on upgrade.

---

## ModelConfig

> **The CRD serves both `v1alpha1` and `v1alpha2`, with different field names.** `v1alpha1`: `apiKeySecretRef`. **`v1alpha2`** (use this): `apiKeySecret` + `apiKeySecretKey`. Getting this wrong = the agent silently has no model.

`spec` fields (v1alpha2):

| Field | Type | Notes |
|---|---|---|
| `provider` | enum | `OpenAI`, `Anthropic`, `AzureOpenAI`, `Ollama`, `Gemini`, `GeminiVertexAI`, `AnthropicVertexAI`, **`Bedrock`**, `SAPAICore` |
| `model` | string | **required** |
| `apiKeySecret` | string | Secret **name** (same ns) |
| `apiKeySecretKey` | string | key within that Secret |
| `apiKeyPassthrough` | bool | forward the *caller's* key to the model instead of a static secret (model-hop identity rail) |
| `openAI` | object | `baseUrl` (point at any OpenAI-compatible endpoint — BYO/fake/agentgateway-LLM-gateway), `tokenExchange`, `temperature`, `maxTokens`, `seed`, … |
| `bedrock` | object | Bedrock-specific config (use with `provider: Bedrock`) |
| `tls` | object | `disableVerify`, `caCertSecretRef`, `caCertSecretKey`, `disableSystemCAs` |

CEL validations enforce: the provider sub-block must match `provider` (e.g. `openAI` only when `provider: OpenAI`); `apiKeySecret` and `apiKeySecretKey` are both-or-neither; `apiKeyPassthrough` is mutually exclusive with a static secret.

Minimal (BYO / fake OpenAI-compatible endpoint):
```yaml
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata: { name: fake-model, namespace: kagent }
spec:
  provider: OpenAI
  model: fake-gpt
  apiKeySecret: kagent-fake-llm      # Secret name
  apiKeySecretKey: OPENAI_API_KEY
  openAI:
    baseUrl: "http://fake-llm.kagent.svc.cluster.local:8080/v1"
```

Bedrock-via-agentgateway (EnterpriseClaw LLM-gateway shape): `provider: Bedrock` (or `OpenAI` with `openAI.baseUrl` at agentgateway), with agentgateway's SA holding the Bedrock IRSA. Verify the exact `bedrock`/`baseUrl` shape against agentgateway's Bedrock provider before relying on it.

---

## Agent

`spec` fields:

| Field | Type | Notes |
|---|---|---|
| `description` | string | |
| `type` | enum | `Declarative` (the common path) |
| `declarative.runtime` | enum | `python` \| `go` |
| `declarative.systemMessage` | string | prompt; supports `{{include "builtin/…"}}` |
| `declarative.modelConfig` | string | **name** of a `ModelConfig` |
| `declarative.tools[]` | array | see below |
| `declarative.a2aConfig.skills[]` | array | exposes the agent over A2A (id/name/description/tags) |

`tools[]` item:
```yaml
- type: McpServer
  mcpServer:
    name: echo-mcp            # name of a RemoteMCPServer / MCPServer / Agent CR
    kind: RemoteMCPServer     # RemoteMCPServer | MCPServer | Agent
    apiGroup: kagent.dev
    toolNames: ["echo"]       # which tools from that server this agent may call
```

Minimal:
```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata: { name: echo-agent, namespace: kagent }
spec:
  description: "JWT-propagation dry-run agent."
  type: Declarative
  declarative:
    runtime: python
    modelConfig: fake-model
    systemMessage: |
      You are a test agent. When asked to probe, call the `echo` tool exactly once,
      then report the headers it returned.
    tools:
      - type: McpServer
        mcpServer: { name: echo-mcp, kind: RemoteMCPServer, apiGroup: kagent.dev, toolNames: ["echo"] }
    a2aConfig:
      skills:
        - id: probe
          name: Header probe
          description: Calls echo and returns received headers.
          tags: ["dry-run"]
```

---

## RemoteMCPServer  (external HTTP MCP; shortName `rmcps`)

`spec` fields:

| Field | Type | Notes |
|---|---|---|
| `description` | string | **required** |
| `url` | string | **required**, minLength 1 — the MCP endpoint |
| `protocol` | enum | `SSE` \| `STREAMABLE_HTTP` — **default `STREAMABLE_HTTP`** (your server must speak it) |
| `timeout` | string | default `30s` |
| `sseReadTimeout` | string | SSE only |
| `terminateOnClose` | bool | default `true` |
| `headersFrom[]` | array | **static** header injection: `{name, value}` or `{name, valueFrom:{type: Secret\|ConfigMap, name, key}}` — **NOT** dynamic incoming-bearer passthrough |
| `tls` | object | `disableVerify`, `caCertSecretRef`, `caCertSecretKey`, `disableSystemCAs` — **rejected by CEL if `url` starts `http://`** (omit `tls` for plaintext) |
| `allowedNamespaces` | object | `{from: Same\|All\|Selector, selector}`, default `Same` |
| `status.discoveredTools[]` | — | `{name, description}` the controller discovered (your sanity check) |

Minimal (plaintext → no `tls`):
```yaml
apiVersion: kagent.dev/v1alpha2
kind: RemoteMCPServer
metadata: { name: echo-mcp, namespace: kagent }
spec:
  description: "echo MCP (header probe)"
  url: "http://echo-mcp.kagent.svc.cluster.local:8080/mcp"   # direct (iteration 1)
  # url: "http://agentgateway.kagent.svc.cluster.local:3000/mcp"  # via gateway (iteration 2)
  protocol: STREAMABLE_HTTP
  timeout: 30s
```

---

## MCPServer  (kmcp — runs an MCP server on-cluster)

Provided by **kmcp** (bundled in the kagent chart; `kmcp.enabled`). Use this instead of `RemoteMCPServer` when EnterpriseClaw should *host* the MCP (e.g. the GitHub MCP for the demo's PR-open path). Reference it from an Agent with `kind: MCPServer`. Verify the exact `MCPServer` spec (image/transport/env/command) with `kubectl explain mcpserver.spec` after install — kmcp's API has churned (ToolServer→kmcp) and the spec is the least-stable of the set.
