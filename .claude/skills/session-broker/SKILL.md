---
name: session-broker
description: >-
  EnterpriseClaw's identity layer — the Session-Broker: the confidential OAuth client that binds a
  slack_user_id to a real Keycloak identity, and how EnterpriseClaw installs + internet-exposes it
  (broker + Keycloak + Redis + Dapr) via GitOps. Use when working on identity/auth, OAuth, Keycloak,
  the two-identity rails (user JWT + workload SPIFFE), Workflow Step 0 (/identity/resolve), the
  no-token login-wall (/auth/login/start), or how `enterpriseclaw init` deploys/exposes the broker.
---

# Session-Broker

The component that **closes EnterpriseClaw's identity gap**. Without it, every privileged action runs
under static infra identities (the Bedrock IRSA SA + the GitHub-App bot) — no per-human authorization,
no human-level audit. The broker binds a Slack user to a **real corporate identity** so the mesh can
authorize *who* (not just *what*).

> **Lives in a SEPARATE repo:** [github.com/jdarguello/Session-Broker](https://github.com/jdarguello/Session-Broker).
> EnterpriseClaw is the **consumer + installer + exposer**, not the owner. See the ownership boundary below.
>
> **Dated knowledge.** Broker-repo facts verified **2026-06-26** against its `main` (`gitops/bootstrap.yaml`,
> `gitops/session-broker/base/*`, `gitops/keycloak/values.yaml`). The broker repo is independently
> developed — re-verify service names / namespaces / chart versions before trusting them on a later commit.

## What it is

A **confidential OAuth client** (Python app, container port 8000) that:
- binds a `slack_user_id` → a real corporate identity (**Google Workspace federated behind Keycloak**),
- mints a one-time `state` nonce + PKCE, performs the `code→token` exchange **itself** (so cached tokens
  are provenance-guaranteed Keycloak-issued), and
- caches the user's **encrypted tokens in Redis via Dapr**.

The agent calls the broker; **the broker is the only component that touches Keycloak on the write path.**

## What `gitops/bootstrap.yaml` installs

That file is an **ApplicationSet `session-broker-platform`** (namespace `argocd`) — "create it in the cluster
and it installs everything." It generates four Argo CD Applications:

| Component | Namespace | Type | Notes |
|---|---|---|---|
| **session-broker** | `session-broker` | Kustomize `gitops/session-broker/overlays/dev` | the broker app itself |
| **keycloak** | `keycloak` | Helm (Bitnami `keycloak` v22.2.3) | `ingress.enabled: false` — **ClusterIP only, no exposure** |
| **redis** | `redis` | Helm (Bitnami v20.3.0) | token cache (via Dapr state store) |
| **dapr** | `dapr-system` | Helm v1.14.4 | sidecar/runtime for the broker |

### Service coordinates (for routing / debugging)

- **broker:** Service `session-broker` in ns `session-broker`, ClusterIP `port 80 → targetPort 8000`,
  selector `app: session-broker`. FQDN `session-broker.session-broker.svc.cluster.local`.
- **keycloak:** Bitnami chart, Service `keycloak` in ns `keycloak`, ClusterIP `port 80`.
  FQDN `keycloak.keycloak.svc.cluster.local`. Back-channel (in-cluster) issuer hits this directly.

## The broker's HTTP surface (per CLAUDE.md §2.2)

| Endpoint | Caller | Path | Auth |
|---|---|---|---|
| `POST /identity/resolve` | Workflow **Step 0** (reader) | resolve `X-Slack-User-Id` → corporate identity / cached token | mTLS-gated; only the workflow-step SA may call it |
| `POST /auth/login/start` | the **no-token login-wall** (writer) | returns a Keycloak `/authorize` URL to post into Slack | workload identity |
| `/auth/callback` | the **browser** (after Keycloak login) | broker does `code→token`, caches in Redis | public (internet-facing) |

**Per-message branch (Step 0):** token found → carry the user JWT into the A2A call; **no token** → call
`/auth/login/start`, post the Keycloak URL to Slack, end the run; the next Slack reply re-fires a fresh
workflow with the token now cached. The login wall is **conditional on intent** (a privileged target),
not on mere auth state.

## Two-identity rails (the demo's headline)

- **User identity** = the Keycloak **JWT** (carries client-scope / groups / roles → "which agents/MCPs/tools").
- **Workload identity** = the ambient-mesh **SPIFFE/mTLS** principal.
- **ztunnel** enforces L4 (mTLS + workload rail); **agentgateway** (the Istio ambient L7 waypoint) validates
  the JWT (JWKS from Keycloak) and authorizes on `source.principal` **and** `jwt.claims`.
- **The model is not the security boundary — the mesh is.** (See the [kagent-trio](../kagent-trio/SKILL.md) skill
  for JWT propagation through kagent→agentgateway→MCP.)

## Ownership boundary (important — don't cross it)

| Owned by the **Session-Broker repo** | Owned by **EnterpriseClaw** |
|---|---|
| Keycloak, Redis, Dapr | Argo Events/Workflows, Istio, the **kagent trio** |
| The OAuth **write/read paths** (Google federation, `code→token`) | The **consumer side**: Workflow Step 0, the login-wall |
| Keycloak realm/clients/roles, `KC_HOSTNAME` | **Istio internet exposure** of broker + keycloak |
| | The **agentgateway authz policy** (claim → agent/MCP/tool) |

The Keycloak helm-app **left this repo in `796d38e`**. The agent calls the broker, **never Keycloak directly**.

## Gotchas that will bite you

1. **Neither broker nor Keycloak is internet-reachable as-installed.** Keycloak ships `ingress.enabled: false`;
   the broker ships its own `session-broker-callback` Ingress but with a **placeholder host**
   (`broker.session-broker.example.com`) and **no subnets**. EnterpriseClaw must provide the exposure →
   `reference/enterpriseclaw-integration.md`.
2. **`KC_HOSTNAME` must be pinned to the external issuer** (`https://auth.<domain>`) in the **broker repo's**
   keycloak values, or issued tokens' `iss` claim won't match what agentgateway validates. **Cannot be fixed
   from EnterpriseClaw** — it's a broker-repo change.
3. **The broker is a confidential client.** Tokens are Keycloak-issued and broker-cached; do not design a path
   where the agent or workflow mints/holds Keycloak tokens itself — provenance must stay broker-guaranteed.
4. **`aud` is a single broad audience for the POC** (validated by agentgateway at each hop). Per-agent token
   exchange is the hardening path, deferred past ArgoCon.
5. **GitHub auth still uses the App/bot creds** — the user JWT governs *whether* the human may invoke a tool
   (agentgateway authz) but stops at the gateway; it does **not** reach GitHub. Human attribution lives in the
   Argo Workflow archive + agentgateway trace.

## How EnterpriseClaw installs + exposes it

`enterpriseclaw init` registers the broker (and the agentic platform) into the tenant app-of-apps **before the
push**, declaratively, so `destroy` prunes it. The CLI mechanics, exposure manifests, the still-open ALB item,
and the unit tests are in **`reference/enterpriseclaw-integration.md`**.
