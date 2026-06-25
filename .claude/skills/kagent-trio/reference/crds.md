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
- type: McpServer            # McpServer | Agent
  mcpServer:
    name: echo-mcp            # name of a RemoteMCPServer / MCPServer / Agent CR
    kind: RemoteMCPServer     # RemoteMCPServer | MCPServer | Agent
    apiGroup: kagent.dev
    toolNames: ["echo"]       # which tools from that server this agent may call
    allowedHeaders:           # *** dynamic incoming-header passthrough to the MCP (see callout) ***
      - Authorization
    # requireApproval: ["..."]  # tool names that need human approval before calling
    # namespace: <ns>           # if the referenced server CR lives in another namespace
```

> **`allowedHeaders` IS the user-JWT propagation mechanism at the kagent hop** — VERIFIED 2026-06-25 (dry-run iteration 1). It **dynamically forwards the listed inbound A2A request headers to the MCP tool call, intact / pass-through (not re-minted)**. Confirmed with an echo-MCP: the exact `Authorization: Bearer <jwt>` sent to the agent reappeared in the MCP's received headers. This is **distinct** from `RemoteMCPServer.headersFrom` (which is *static*, from a Secret). Two more findings: (1) it works **independent of `controller.auth.mode`** — the header forwards even when you hit the agent pod directly (bypassing the controller's trusted-proxy user extraction); (2) field lives on the **Agent's tool ref**, NOT on `RemoteMCPServer`. So an MCP behind kagent only ever sees a header you explicitly allow-list here.

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
        mcpServer:
          name: echo-mcp
          kind: RemoteMCPServer
          apiGroup: kagent.dev
          toolNames: ["echo"]
          allowedHeaders: ["Authorization"]   # forward the inbound user bearer to the MCP
    a2aConfig: {}        # presence (even empty) instantiates the per-agent A2A server; `skills` is optional
```

### Reaching a Declarative agent over A2A (verified 2026-06-25)

`a2aConfig` (even `{}`) runs a **per-agent A2A server on the pod's HTTP port `:8080`**, exposed as a ClusterIP Service `<agent-name>.<ns>` (e.g. `echo-agent.kagent:8080`). A2A goes **straight to the agent pod, NOT through the controller** (`kagent-controller:8083` does not serve the agent card).

- Agent card: `GET /.well-known/agent-card.json` (also `/.well-known/agent.json`) → `preferredTransport: JSONRPC`, `protocolVersion: 0.3`, `url` = the JSON-RPC endpoint (the pod base URL).
- Drive a tool call with JSON-RPC `message/send` (A2A 0.3 — note `kind`, not `type`, on parts):
  ```json
  {"jsonrpc":"2.0","id":"1","method":"message/send",
   "params":{"message":{"role":"user","kind":"message",
     "parts":[{"kind":"text","text":"..."}],"messageId":"<uuid>"}}}
  ```
- Response = a Task: `result.history[]` carries the model turns incl. the tool `function_call` / `function_response` (the MCP's returned content is here), plus `result.artifacts[]` with the final text. `result.history[].metadata.kagent_user_id` shows the resolved user — `A2A_USER_<contextId>` when hit directly (controller trusted-proxy not in path).

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
