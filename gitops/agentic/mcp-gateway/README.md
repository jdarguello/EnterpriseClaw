# MCP waypoint — the authorization catalog

This directory is the **enforcement plane** for the agent's tools: the agentgateway L7 waypoint that
validates the Keycloak user JWT and **claim-gates which MCP each human may reach**. It is the
framework-level *catalog* (target → required claim) from [§2.2](../../../.claude/CLAUDE.md); the
role→user assignment lives tenant-side in the Session-Broker `enterpriseclaw` realm.

## The catalog

| Route (on `agentic-mcp-gw`) | Upstream MCP | Required audience | Required capability (CEL on the validated JWT) |
|---|---|---|---|
| `/issues` | `github-issues` | `issue-tracker` | `issue:create` in `resource_access["issue-tracker"].roles` |
| `/provisioning` | `infra-provisioning` | `infra-provisioner` | `db:provision:dev` in `resource_access["infra-provisioner"].roles` |

Mapped onto the realm's demo users:

| User | Group → roles | `/issues` | `/provisioning` |
|---|---|---|---|
| *(unauthenticated)* | — (no JWT) | **401** | **401** |
| `alice` | `/engineering` → `agent-user`, `issue:create`, `infra:read` | ✅ | **403** |
| `juandavidarguello@gmail.com` | `/engineering/seniors` → `+senior-engineer` → `+db:provision:dev` | ✅ | ✅ |
| *(anyone)* | `db:provision:prod` is granted to **nobody** | — | a `prod` route would **403** even juan |

Headline: **two authenticated users, the same agent — the mesh lets one provision and blocks the
other, on Keycloak claims alone. The model is not the security boundary.**

## How it's enforced (proven shape)

Per the dry-run (stage B PASSED 2026-06-25, see the kagent-trio skill's `jwt-propagation.md`):
`jwtAuthentication` **and** `authorization` both live under `traffic` on the HTTPRoute, with
`mode: Strict` (only Strict populates `jwt.*` for the CEL and rejects tokenless/forged). The
validated bearer is **consumed at the gateway** — it does not continue to GitHub (no
`backend.auth.passthrough`); GitHub-side auth is the MCP's own `github-creds` token. `issuer`/JWKS
point at the in-cluster Keycloak (`http://keycloak.keycloak.svc/realms/enterpriseclaw`, verified
live 2026-06-26).

## Testing it

- **Direct (proves enforcement now):** drive `…/issues` and `…/provisioning` on the proxy with real
  alice / juan tokens (and none/forged) — exactly the dry-run method. Independent of the MCP pods
  being Ready, because the gateway decides before contacting the upstream.
- **Through kagent (full agent path):** needs the `mcp-discovery-token` Secret so the controller's
  tokenless tool discovery survives `Strict` (see `remotemcpservers.yaml`).

## Prereqs (not committed)

- `github-creds` (ns `kagent`) — the MCP upstreams' GitHub token (see [../mcps/](../mcps/)).
- `mcp-discovery-token` (ns `kagent`, key `authorization` = `"Bearer <jwt>"`) — the bearer the kagent
  controller uses for tokenless tool **discovery**, which must survive `Strict` on both routes. Source it
  from a **`kagent-controller` service-account** in the realm (`client_credentials`, with **both**
  audiences `issue-tracker`+`infra-provisioner` and **both** capability roles `issue:create`+`db:provision:dev`,
  so one token passes both `/issues` and `/provisioning`). It's a *workload* credential (the controller's),
  not a user's. `headersFrom` resolves it at **compile time** — if absent, the `RemoteMCPServer`/`Agent` go
  `ACCEPTED=False`. Provenance + the verified result are in the kagent-trio skill's `jwt-propagation.md`.
