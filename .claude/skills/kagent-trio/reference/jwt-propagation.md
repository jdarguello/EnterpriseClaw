# JWT / identity propagation through the trio

This is the **riskiest unknown** of the EnterpriseClaw demo (CLAUDE.md §2.2) and the reason for the dry-run. Verified understanding as of 2026-06-24.

## Two identity rails — do not conflate

| Rail | Identity | Enforced by | Hop |
|---|---|---|---|
| **User** | Keycloak **JWT** (scopes/groups/roles/claims) | **agentgateway** (L7): `traffic.jwtAuthentication` (JWKS, `mode: Strict`) + `traffic.authorization` CEL on `jwt.*` — both on the HTTPRoute (NOT `backend.mcp.*`; see stage-B box) | A2A ingress → MCP tool calls |
| **Workload** | ambient-mesh **SPIFFE/mTLS** principal | **ztunnel** (L4) + agentgateway authz on `source.principal` | every pod-to-pod hop |
| **Model** | static key / IRSA / passthrough | agentgateway LLM gateway (`backendAuth: aws` SigV4 + Bedrock IRSA) | agent → LLM (Bedrock) |

The **model hop is a separate rail** from the MCP-tool hop. kagent's `ModelConfig.apiKeyPassthrough` and `openAI.tokenExchange` operate on the *model* rail — they are **not** the mechanism for getting the user JWT to MCP tools.

## The core problem

**Propagation is upstream of enforcement.** No policy engine (agentgateway *or* Istio) can authorize a token that was never put on the wire. So the question is: **does the user bearer survive `A2A client → agentgateway → kagent → (agentgateway) → MCP`, intact and not re-minted?**

What's known (★ = empirically verified in the dry-run, 2026-06-25):
- **kagent — ★ DOES forward natively, via `Agent.declarative.tools[].mcpServer.allowedHeaders`.** The earlier hypothesis ("no dynamic forwarding; only static `RemoteMCPServer.headersFrom`") was **WRONG**. The dynamic lever is a per-tool **allow-list of inbound headers** on the *Agent's tool ref* (not on `RemoteMCPServer`). With `allowedHeaders: ["Authorization"]`, the inbound A2A bearer reaches the MCP tool call **intact / pass-through (not re-minted)** — confirmed by an echo-MCP echoing back the exact token. `headersFrom` is the *static* (Secret) mechanism; `allowedHeaders` is the *dynamic incoming-bearer* one. An MCP only ever sees a header you explicitly allow-list. **So fallback-ladder step 1 is sufficient at the kagent hop — agentgateway passthrough is NOT required just to get the bearer past kagent.**
- **agentgateway — ★ forwards inbound `Authorization` to an MCP backend by DEFAULT (2026-06-25, iter2 stage A).** The earlier claim ("strips unless `backendAuth: passthrough: {}`") was **WRONG for MCP backends**: with the `AgentgatewayPolicy` *deleted entirely* (no `backend.auth` at all, 25 s for xDS), echo-MCP still received the exact bearer. `backend.auth` configures how the proxy authenticates *to* the upstream when you want it to **inject/replace** creds (`aws` SigV4 for Bedrock, static `key`/`secretRef`); `passthrough: {}` is the *explicit* "forward incoming auth," but for MCP backends pass-through is the default anyway. (The "strips + replace" behavior likely still holds for **AI/LLM** backends, where the provider credential replaces `Authorization` — untested.) The agentgateway proxy is genuinely MCP-protocol-aware: its access log shows `protocol=mcp mcp.method.name=tools/call mcp.target=echo gen_ai.tool.name=echo` — which is exactly what makes `mcp.tool.name` available to `mcpAuthorization` CEL. **Still un-verified:** JWKS validation (`jwtAuthentication`) + claim-gated `mcpAuthorization` — that's iter2 stage B (needs a real signed token).
- `controller.auth.mode: trusted-proxy` governs the **inbound** JWT to the controller/A2A — **not** outbound MCP propagation. ★ Confirmed orthogonal: `allowedHeaders` forwarded the bearer to MCP even when the agent pod was hit **directly** (controller trusted-proxy not in path; `kagent_user_id` fell back to `A2A_USER_<contextId>` rather than the JWT `sub`). I.e. MCP header passthrough ≠ kagent's own user-identity extraction; they're independent.

## The dry-run (de-risk before building the spine)

Isolate the variable, riskiest hop first. Two iterations:

1. **Iteration 1 — kagent hop alone. ✅ DONE 2026-06-25 — PASSED.** Agent's `RemoteMCPServer.url` points **directly** at an **echo-MCP** (returns the headers it received); a fake OpenAI-compatible `ModelConfig.openAI.baseUrl` forces a deterministic `echo` tool_call (isolating from Bedrock). Drove A2A `message/send` to the agent pod with `Authorization: Bearer <jwt>` + `allowedHeaders: ["Authorization"]` on the tool. **Result: the exact bearer reached echo-MCP, intact.** Caveat: run with a **synthetic `alg:none` JWT** (iteration 1 has no validator) — re-run with a real signed Keycloak token alongside iteration 2.
2. **Iteration 2 — add the L7 hop.** Repoint `RemoteMCPServer.url` at the agentgateway proxy (a `Gateway` class `agentgateway` → `AgentgatewayBackend` kind `mcp` → `HTTPRoute` → `AgentgatewayPolicy`). Two stages:
   - **Stage A — bearer survives the L7 hop. ✅ DONE 2026-06-25 — PASSED (synthetic token).** With the kagent `RemoteMCPServer` pointed at the proxy and `allowedHeaders: ["Authorization"]` still on the tool, echo-MCP received the exact bearer through `kagent → agentgateway → echo-MCP`. Proxy logs confirm it transited the waypoint (`host: agw-dryrun…`, `mcp.method.name=tools/call`). **And** the bearer forwards even with no policy at all (see the agentgateway bullet above).
   - **Stage B — JWKS validation + claim-gated authz. ✅ DONE 2026-06-25 — PASSED (real RS256 Keycloak token).** Provisioned an `enterpriseclaw` realm (role `mcp-user`, client `dryrun-cli`, users `alice`=role / `bob`=no-role, audience `enterpriseclaw-agents`) and drove the gateway's MCP endpoint directly with each token. **Result: alice (has `mcp-user`) → echo runs; bob → 403; no-token → 401; forged-signature → 401 `InvalidSignature`.** agentgateway validates **signature (remote Keycloak JWKS) + issuer + audience + presence** and **claim-gates on the realm role**. This is the demo's headline ("Keycloak claims → which MCP/tool the human reaches," enforced by the mesh not the model). The hard-won 1.3.1 config gotchas are in the box below.

> **Stage-B agentgateway 1.3.1 config gotchas (each cost a debug cycle — bake these in):**
> 1. **`backend.mcp.authentication` is UNUSABLE.** CRD exposes only a *remote* `jwks.backendRef`, but the runtime xDS **NACKs**: *"MCP Authentication requires jwks_inline to be set."* → do JWT **validation** in **`traffic.jwtAuthentication`** (route-level), which supports `jwks.remote` **and** `jwks.inline`.
> 2. **`jwt.*` does NOT reach `backend.mcp.authorization`'s CEL** when validation is route-level — it filtered the tool even for a user *with* the role (looks like "Unknown tool"). → keep **authorization at the same `traffic` level** (`traffic.authorization`, `action: Allow`, `policy.matchExpressions`) as validation, where `jwt.*` is in scope. For a single-tool MCP a route-gate == a tool-gate; per-`mcp.tool.name` granularity via `backend.mcp.authorization` is unconfirmed on 1.3.1.
> 3. **Mode semantics (empirical, undocumented):** **`Strict`** = validate + reject tokenless (401) + **populate `jwt.*` for the authz CEL**. **`Permissive`** = lets tokenless through **but does NOT populate `jwt.*`** → authz then denies *even a valid token*. `Optional` also 401s tokenless MCP. **So `Strict` is required for claim-based authz to work.** Trade-off: `Strict` 401s the kagent **controller's tokenless tool discovery** → see the open end-to-end item below.
> 4. **Issuer must match byte-for-byte.** Keycloak reflects the request **Host** into `iss`; a token minted via `keycloak.keycloak.svc.cluster.local` vs the configured `keycloak.keycloak.svc` → `Error(InvalidIssuer)`. Pin the mint host (or `KC_HOSTNAME`) so `iss` == `jwtAuthentication.providers[].issuer`.
> 5. **Nested CEL works:** `'"mcp-user" in jwt.realm_access.roles'` (Keycloak realm roles) is fine — an earlier failure was #4 (issuer), not the nested path.
> 6. **Under active `jwtAuthentication` the validated bearer is CONSUMED at the gateway** (not forwarded to the MCP) — the opposite of stage A (no-jwt → forwarded by default). `backend.auth.passthrough` is the documented lever to **re-forward** it (needed only if the upstream MCP itself consumes the user token; the EnterpriseClaw POC wants the user JWT to *stop* at the gateway, so leave it off).
>
> **Open end-to-end item:** the *direct-to-gateway* probe proves enforcement; *through kagent* needs the controller's **tokenless discovery** to survive `Strict` (today it 401s). Fix path: give `RemoteMCPServer.headersFrom` a static discovery token (mcp-user) for tools/list, and verify the per-call `allowedHeaders` user bearer takes precedence over it for `tools/call`. Then alice's A2A call → allowed, bob's → denied, fully through the agent.

Rig: a bare cluster (this project uses a UTM VM reachable via `ssh controlplane`, with real Keycloak/Session-Broker already running) + Argo CD delivering [gitops/dry-run/](../../../gitops/dry-run/). Echo-MCP and fake-LLM are stdlib stubs (no images to build).

## Fallback ladder — ★ step 1 WINS at the kagent hop (2026-06-25)

Per CLAUDE.md §2.2, in order of preference:
1. **kagent header-passthrough config — ✅ CONFIRMED: `Agent…tools[].mcpServer.allowedHeaders: ["Authorization"]`.** This is the native lever; no need to descend the ladder for the kagent hop. →
2. **agentgateway** — ★ for **MCP backends the bearer passes through to the upstream by default** (iter2 stage A; `backend.auth.passthrough` not required just to forward it). agentgateway is still where JWKS validation (`jwtAuthentication`) + `mcpAuthorization` live for iteration 2 stage B; `backend.auth` is for *injecting* upstream creds, not for forwarding the user bearer. →
3. patch/PR kagent to forward the bearer — **not needed.** →
4. restructure so the **Workflow** performs the token-bearing step — **not needed** (would have broken "the agent decides to call the tool").

## The triage / no-token door (security invariant)

The intentional JWT-less path is a **read-only triage agent** whose SPIFFE principal is in **no MCP's allow-list** — so mTLS/agentgateway refuse it at the identity layer even under full prompt injection. **The model is not the security boundary — the mesh is.** A tokenless privileged tool call must be *rejected*, not best-effort allowed.
