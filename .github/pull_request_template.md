<!--
  EnterpriseClaw PR template — DUAL-USE.
  The block above the divider is the contract for EVERY PR, human or agent-opened
  (the platform-agent fills the same shape when it opens a Crossplane-Claim PR on stage).
  Keep it minimal and machine-friendly. The "Reviewer gates" block below the divider is
  human-only — an agent may leave it untouched without producing a malformed PR.
-->

## Closes

<!-- e.g. Closes #123. Every PR should trace back to an issue. -->
Closes #

## Area(s)

<!-- cli · infra · gitops · actions · agentic · identity · docs -->

## What changed & why

<!-- The change in a few sentences, and the intent behind it. For an agent-opened PR this
     is the reasoning: what was asked, and what this PR proposes (e.g. the Crossplane Claim). -->

## Verification / evidence

<!-- How this was proven against a LIVE environment (sandbox / dry-run VM / local), not just
     "it builds". Paste the signal — command output, a green testing-agent run, a 200 from the
     endpoint. Redact secret values. -->

---

### Reviewer gates (human-only — safe for an agent to leave unchecked)

- [ ] **Status honesty** — this PR does not overclaim "done"; CLAUDE.md §4 status updated if a capability's state changed.
- [ ] **Secret hygiene** — no secret values in the diff; any new Secrets-Manager key an ExternalSecret reads is registered in `secrets_registries` (or created by the module).
- [ ] **Identity / mesh impact** — if this touches auth (a JWT hop, MCP allow-list, SPIFFE rail, authz policy), the trust-boundary effect is described above; otherwise n/a.
- [ ] **Teardown / rollback** — considered how this behaves on `main destroy` and on Argo self-heal (no manual `kubectl edit` that selfHeal reverts).
