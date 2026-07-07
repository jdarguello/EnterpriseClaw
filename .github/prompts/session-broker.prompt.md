---
mode: agent
description: Load the Session-Broker / identity reference before working on OAuth, Keycloak, or the two identity rails.
---

# Session-Broker / identity reference

Use this when working on **identity/auth, OAuth, Keycloak, the two identity rails** (user
JWT + workload SPIFFE), **Workflow Step 0** (`/identity/resolve`), the **no-token login
wall** (`/auth/login/start`), or how `enterpriseclaw init` deploys/exposes the broker stack.

The **Session-Broker** is the confidential OAuth client that binds a `slack_user_id` to a
real Keycloak identity (Google Workspace federated behind Keycloak), caching encrypted
tokens in Redis via Dapr. **Ownership boundary:** Keycloak + Redis + Dapr and the OAuth
write/read paths live in the *separate* Session-Broker repo — EnterpriseClaw is the
**consumer** (Step 0 resolve, the login wall, the agentgateway JWT/claims authz) and
**provisions the broker stack's secrets** (SM `keycloak-internal` + ExternalSecrets). The
agent calls the broker, **never Keycloak directly**.

**Read these repo files before answering or editing:**
- `.claude/skills/session-broker/SKILL.md` (overview + entry points)
- `.claude/skills/session-broker/reference/enterpriseclaw-integration.md` (how init
  deploys/exposes the broker; secret wiring; the `session-broker-bootstrap` naming footgun)
- `.claude/skills/session-broker/reference/keycloak-debugging.md` (realm import, Google IdP
  mapper, slow-boot behavior)
- `.claude/skills/session-broker/reference/broker-side-change.prompt.md` (when a change must
  land in the *broker* repo, not here)

Remember: strong fine-grained **user identity** (Keycloak JWT, scope-by-scope) + a
present-but-coarse **workload identity** (ambient SPIFFE). Both rails are enforced at the
mesh (ztunnel L4 + agentgateway L7), never by the LLM. **Never reproduce secret values** —
keys/fields by name only.
