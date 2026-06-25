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

What's known (★ = empirically verified in the dry-run, 2026-06-25):
- **kagent — ★ DOES forward natively, via `Agent.declarative.tools[].mcpServer.allowedHeaders`.** The earlier hypothesis ("no dynamic forwarding; only static `RemoteMCPServer.headersFrom`") was **WRONG**. The dynamic lever is a per-tool **allow-list of inbound headers** on the *Agent's tool ref* (not on `RemoteMCPServer`). With `allowedHeaders: ["Authorization"]`, the inbound A2A bearer reaches the MCP tool call **intact / pass-through (not re-minted)** — confirmed by an echo-MCP echoing back the exact token. `headersFrom` is the *static* (Secret) mechanism; `allowedHeaders` is the *dynamic incoming-bearer* one. An MCP only ever sees a header you explicitly allow-list. **So fallback-ladder step 1 is sufficient at the kagent hop — agentgateway passthrough is NOT required just to get the bearer past kagent.**
- **agentgateway**: forwards the validated bearer to the MCP upstream **only** with `backendAuth: passthrough: {}` — it **strips** otherwise. Still relevant for iteration 2 (the L7 hop sits between kagent and the MCP and does JWKS validation + `mcpAuthorization`). *Not yet dry-run-verified.*
- `controller.auth.mode: trusted-proxy` governs the **inbound** JWT to the controller/A2A — **not** outbound MCP propagation. ★ Confirmed orthogonal: `allowedHeaders` forwarded the bearer to MCP even when the agent pod was hit **directly** (controller trusted-proxy not in path; `kagent_user_id` fell back to `A2A_USER_<contextId>` rather than the JWT `sub`). I.e. MCP header passthrough ≠ kagent's own user-identity extraction; they're independent.

## The dry-run (de-risk before building the spine)

Isolate the variable, riskiest hop first. Two iterations:

1. **Iteration 1 — kagent hop alone. ✅ DONE 2026-06-25 — PASSED.** Agent's `RemoteMCPServer.url` points **directly** at an **echo-MCP** (returns the headers it received); a fake OpenAI-compatible `ModelConfig.openAI.baseUrl` forces a deterministic `echo` tool_call (isolating from Bedrock). Drove A2A `message/send` to the agent pod with `Authorization: Bearer <jwt>` + `allowedHeaders: ["Authorization"]` on the tool. **Result: the exact bearer reached echo-MCP, intact.** Caveat: run with a **synthetic `alg:none` JWT** (iteration 1 has no validator) — re-run with a real signed Keycloak token alongside iteration 2.
2. **Iteration 2 — add the L7 hop (NEXT).** Repoint `RemoteMCPServer.url` at **agentgateway** (`jwtAuth` + `backendAuth: passthrough` + `mcpAuthorization`). Assert the bearer survives `kagent → agentgateway → echo-MCP` and that a claim-gated tool is allowed/denied by `jwt.*`. Use a **real RS256 Keycloak token** here (agentgateway validates JWKS). Keep `allowedHeaders: ["Authorization"]` on the kagent tool so kagent forwards into agentgateway.

Rig: a bare cluster (this project uses a UTM VM reachable via `ssh controlplane`, with real Keycloak/Session-Broker already running) + Argo CD delivering [gitops/dry-run/](../../../gitops/dry-run/). Echo-MCP and fake-LLM are stdlib stubs (no images to build).

## Fallback ladder — ★ step 1 WINS at the kagent hop (2026-06-25)

Per CLAUDE.md §2.2, in order of preference:
1. **kagent header-passthrough config — ✅ CONFIRMED: `Agent…tools[].mcpServer.allowedHeaders: ["Authorization"]`.** This is the native lever; no need to descend the ladder for the kagent hop. →
2. **agentgateway `backendAuth: passthrough`** re-attaching the bearer — still the mechanism for the *agentgateway→MCP* hop in iteration 2 (and where JWKS validation + `mcpAuthorization` live), but **not** needed to get the bearer *past kagent*. →
3. patch/PR kagent to forward the bearer — **not needed.** →
4. restructure so the **Workflow** performs the token-bearing step — **not needed** (would have broken "the agent decides to call the tool").

## The triage / no-token door (security invariant)

The intentional JWT-less path is a **read-only triage agent** whose SPIFFE principal is in **no MCP's allow-list** — so mTLS/agentgateway refuse it at the identity layer even under full prompt injection. **The model is not the security boundary — the mesh is.** A tokenless privileged tool call must be *rejected*, not best-effort allowed.
