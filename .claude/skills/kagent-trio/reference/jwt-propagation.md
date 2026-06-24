# JWT / identity propagation through the trio

This is the **riskiest unknown** of the EnterpriseClaw demo (CLAUDE.md §2.2) and the reason for the dry-run. Verified understanding as of 2026-06-24.

## Two identity rails — do not conflate

| Rail | Identity | Enforced by | Hop |
|---|---|---|---|
| **User** | Keycloak **JWT** (scopes/groups/roles/claims) | **agentgateway** (L7): `jwtAuth` (JWKS) + `mcpAuthorization` CEL on `jwt.*` | A2A ingress → MCP tool calls |
| **Workload** | ambient-mesh **SPIFFE/mTLS** principal | **ztunnel** (L4) + agentgateway authz on `source.principal` | every pod-to-pod hop |
| **Model** | static key / IRSA / passthrough | agentgateway LLM gateway (`backendAuth: aws` SigV4 + Bedrock IRSA) | agent → LLM (Bedrock) |

The **model hop is a separate rail** from the MCP-tool hop. kagent's `ModelConfig.apiKeyPassthrough` and `openAI.tokenExchange` operate on the *model* rail — they are **not** the mechanism for getting the user JWT to MCP tools.

## The core problem

**Propagation is upstream of enforcement.** No policy engine (agentgateway *or* Istio) can authorize a token that was never put on the wire. So the question is: **does the user bearer survive `A2A client → agentgateway → kagent → (agentgateway) → MCP`, intact and not re-minted?**

What's known:
- **kagent**: *no documented dynamic forwarding* of the incoming A2A `Authorization` bearer to its outbound MCP calls. The only header mechanism on `RemoteMCPServer` is **`headersFrom`** — **static**, from a Secret. So the user bearer likely does **not** propagate natively at the kagent hop. (Empirically confirm in the dry-run.)
- **agentgateway**: forwards the validated bearer to the MCP upstream **only** with `backendAuth: passthrough: {}` — it **strips** otherwise. This is the dynamic lever, and it sits exactly between kagent and the MCP.
- `controller.auth.mode: trusted-proxy` governs the **inbound** JWT to the controller/A2A (via oauth2-proxy) — not outbound MCP propagation.

## The dry-run (de-risk before building the spine)

Isolate the variable, riskiest hop first. Two iterations:

1. **Iteration 1 — kagent hop alone.** Agent's `RemoteMCPServer.url` points **directly** at an **echo-MCP** (a tiny MCP that returns the HTTP headers it received). Drive a tool call (a fake OpenAI-compatible `ModelConfig.openAI.baseUrl` makes it deterministic, isolating from Bedrock). Send A2A `message/send` with `Authorization: Bearer <real Keycloak JWT>`. **Assert** whether the bearer appears in the echo-MCP's received headers. → answers "does kagent forward natively?"
2. **Iteration 2 — add the L7 hop.** Repoint `RemoteMCPServer.url` at **agentgateway** (`jwtAuth` + `backendAuth: passthrough` + `mcpAuthorization`). Assert the bearer survives `kagent → agentgateway → echo-MCP` and that a claim-gated tool is allowed/denied by `jwt.*`.

Rig: a bare cluster (this project uses a UTM VM reachable via `ssh controlplane`, with real Keycloak/Session-Broker already running) + Argo CD delivering [gitops/dry-run/](../../../gitops/dry-run/). Echo-MCP and fake-LLM are stdlib stubs (no images to build).

## Fallback ladder (if kagent doesn't forward natively — expected)

Per CLAUDE.md §2.2, in order of preference:
1. kagent header-passthrough config (if any emerges) →
2. **agentgateway `backendAuth: passthrough`** re-attaching the session bearer (the likely answer — agentgateway is already in the path) →
3. patch/PR kagent to forward the bearer →
4. restructure so the **Workflow** (not the agent) performs the mutating token-bearing step — last resort; breaks "the agent decides to call the tool."

## The triage / no-token door (security invariant)

The intentional JWT-less path is a **read-only triage agent** whose SPIFFE principal is in **no MCP's allow-list** — so mTLS/agentgateway refuse it at the identity layer even under full prompt injection. **The model is not the security boundary — the mesh is.** A tokenless privileged tool call must be *rejected*, not best-effort allowed.
