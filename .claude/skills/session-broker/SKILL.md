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
| Keycloak, Redis, Dapr (the **charts**) | Argo Events/Workflows, Istio, the **kagent trio** |
| The OAuth **write/read paths** (Google federation, `code→token`) | The **consumer side**: Workflow Step 0, the login-wall |
| Keycloak realm/clients/roles, `KC_HOSTNAME` | **Istio internet exposure** of broker + keycloak |
| The chart **values** (`existingSecret` *names*, realm `$(env:…)` *keys*) | **The SECRET VALUES those charts consume** — provisioned here via SM `keycloak-internal` + `google-idp` → ExternalSecrets (see below) |
| | The **agentgateway authz policy** (claim → agent/MCP/tool) |

The Keycloak helm-app **left this repo in `796d38e`**. The agent calls the broker, **never Keycloak directly**.
**But secret management lives here:** the broker repo's charts declare `existingSecret` names + realm `$(env:…)` keys; **EnterpriseClaw fills them** (SM `keycloak-internal` + the externally-managed `google-idp`, surfaced as ExternalSecrets by `cli/gitops/broker-keycloak-config.nu`). See `reference/enterpriseclaw-integration.md` → "Secret wiring".

## Gotchas that will bite you

1. **Neither broker nor Keycloak is internet-reachable as-installed.** Keycloak ships `ingress.enabled: false`;
   the broker ships its own `session-broker-callback` Ingress but with a **placeholder host**
   (`broker.session-broker.example.com`) and **no subnets**. EnterpriseClaw must provide the exposure →
   `reference/enterpriseclaw-integration.md`.
2. **`KC_HOSTNAME` / external issuer is split across repos (resolved 2026-06-26).** The tenant host
   (`https://auth.<domain>`) is end-user config: **EnterpriseClaw supplies it** from the private repo as
   `keycloak-hostnames` ConfigMaps (`cli/gitops/broker-keycloak-config.nu`). The **broker repo must consume
   them** via a small `$(env:…)` seam — the realm's `redirectUris`/`webOrigins` are a sub-string of one
   monolithic Helm string and **cannot** be patched remotely, so without the broker change Keycloak rejects
   the callback and login fails. Full contract + the exact broker change: `reference/enterpriseclaw-integration.md`.
3. **The broker is a confidential client.** Tokens are Keycloak-issued and broker-cached; do not design a path
   where the agent or workflow mints/holds Keycloak tokens itself — provenance must stay broker-guaranteed.
4. **`aud` is a single broad audience for the POC** (validated by agentgateway at each hop). Per-agent token
   exchange is the hardening path, deferred past ArgoCon.
5. **GitHub auth still uses the App/bot creds** — the user JWT governs *whether* the human may invoke a tool
   (agentgateway authz) but stops at the gateway; it does **not** reach GitHub. Human attribution lives in the
   Argo Workflow archive + agentgateway trace.
6. **NAME COLLISION (cost a full stack-prune 2026-06-29).** The Application that installs the broker's
   `session-broker-platform` ApplicationSet **must be named `session-broker-bootstrap`, NOT `session-broker`** —
   the AppSet generates a *child* literally named `session-broker` (the broker overlay). Sharing the name makes
   one Argo object owned by two controllers (the app-of-apps installer + the AppSet) that flip-flop the source
   and **deadlock on the `resources-finalizer`** (wedges in `Terminating`); clearing that finalizer then
   completes the pending deletion and **cascade-prunes keycloak/redis/dapr**. Fixed in `cli/gitops/app-of-apps.nu`
   (`session-broker-app` generator). If you ever recreate a pruned broker tree, fix the name collision *first*.
7. **The stack stays in `CreateContainerConfigError` until its secrets exist.** keycloak (`keycloak-admin-secret`,
   `keycloak-postgresql-secret`, `keycloak-realm-secrets`), session-broker (`session-broker-secret`), and redis
   (`redis-secret`) all reference `existingSecret`s EnterpriseClaw must provide — the SM secret `keycloak-internal`
   must exist (created by the `secrets-manager` tofu module) and `terraform_user` needs SM **write** perms to create
   it. `google-idp` (Google OAuth `CLIENT_ID`/`CLIENT_SECRET`) must pre-exist in SM for the realm's Google IdP.
   The realm-import Job (`keycloak-config-cli`) only runs once `keycloak-realm-secrets` exists. See
   `reference/enterpriseclaw-integration.md` → "Secret wiring".
8. **Google-federation login has TWO ordered failure modes (both hit 2026-07-01).** After the login wall posts the
   Keycloak URL and the user picks "Sign in with Google": **(a) Google `Error 400: redirect_uri_mismatch`** — the
   Google OAuth client must register the EXACT Keycloak broker callback
   `https://auth.<domain>/realms/enterpriseclaw/broker/google/endpoint` (the bare root URL and the localhost dev URL
   do NOT match). **(b) Keycloak "Unexpected error when authenticating with identity provider"** — a **realm IdP-mapper
   config bug**, not creds/network: Google auth + `code→token` succeed, then Keycloak NPEs applying the realm's Google
   IdP mappers (`IdentityBrokerService.authenticated … "target" is null`) because a mapper's `identityProviderMapper`
   type id doesn't resolve. The realm used the invalid `hardcoded-group-idp-mapper`; the correct OIDC id is
   **`oidc-hardcoded-group-idp-mapper`**. Both fixes + the live-debug recipe (kcadm on the Bitnami image) →
   `reference/keycloak-debugging.md`. The realm import lives in the **broker repo** (`gitops/keycloak/values.yaml`);
   a live kcadm patch is reverted by the next broker re-sync unless the source file is also fixed.

## How EnterpriseClaw installs + exposes it

`enterpriseclaw init` registers the broker (and the agentic platform) into the tenant app-of-apps **before the
push**, declaratively, so `destroy` prunes it. It also exposes the broker+Keycloak on the **shared platform ALB**
(one IngressGroup, host-based routing) and writes the **tenant hostname ConfigMaps** the broker consumes. The CLI
mechanics, exposure manifests, the hostname contract + the remaining broker-side change, and the unit tests are in
**`reference/enterpriseclaw-integration.md`**.
