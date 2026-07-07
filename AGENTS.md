# AGENTS.md — EnterpriseClaw

Portable agent guide for any AI coding tool (GitHub Copilot coding agent, and others that
read `AGENTS.md`). The full, Copilot-specific instructions live in
[`.github/copilot-instructions.md`](.github/copilot-instructions.md) — read that first;
this file is the fast orientation plus the non-negotiable rules.

## In one breath
EnterpriseClaw stands up a security-hardened AI-assistant control plane on Kubernetes. A
**Nushell CLI** (`enterpriseclaw`, in **Devbox**) goes zero-to-running: **OpenTofu** on
**AWS/EKS** → **Argo CD** app-of-apps → **Argo Events + Workflows** (one short-lived run
per inbound **Slack** message) → the **kagent trio** (kagent + kmcp + agentgateway) on
**Istio ambient** runs the agent (**Claude on AWS Bedrock**) and its MCP tools → the agent
opens a **PR** with a **Crossplane** Claim → Argo CD syncs → Crossplane reconciles it.
Near-term goal: a **talk + demo for ArgoCon Japan** (~July 2026).

## The two ideas everything hangs on
1. **AI proposes; a governed, auditable GitOps pipeline disposes.**
2. **The model is not the security boundary — the service mesh is.** Reachability is
   decided by workload SPIFFE (ztunnel, L4) + Keycloak JWT claims (agentgateway, L7),
   never by the LLM. A prompt-injected agent still cannot reach a tool its identity isn't
   allow-listed for.

## Golden rules (do not violate)
- **AWS only** for now — azure/gcp/gitlab and PR mode (`gitops-setup=pull`) are aspirational
  stubs; build them only when explicitly asked.
- **Never print or commit secret values** (`cli/.env`, `*.pem`, tfvars secrets, tokens) —
  refer to keys/fields by name.
- **Sandbox tenant values in the public repo are intentional** throwaway data — don't
  re-flag them; just don't add new ones (parameterize instead).
- **Public repo (`gitops/`) stays tenant-agnostic; the private repo holds per-tenant data.**
- **tfvars are generated** (`cli/infra/vars.nu`), never hand-edited.
- **Evolve via Issues → PRs** with the `.github/` templates; the PR must `Closes #<issue>`
  and fill verification with a signal from a **LIVE env, not "it builds"**.
- **Be honest about status** — much is decided-but-unimplemented or dry-run-only. Verify
  before claiming "done".

## Area map — route work to the owning area
| Area | Paths | Detailed rules |
|---|---|---|
| CLI (Nushell) | `cli/**` | `.github/instructions/cli.instructions.md` |
| AWS IaC (OpenTofu) | `infrastructure/aws/**`, `cli/infra/vars.nu` | `.github/instructions/infra.instructions.md` |
| GitOps / Argo | `gitops/**` | `.github/instructions/gitops.instructions.md` |
| Action images | `actions/**` | `.github/instructions/actions.instructions.md` |

Deep mechanism references (kagent trio, Session-Broker/identity, Slack door, docs) live
under `.claude/skills/**` and are surfaced as Copilot prompt files in `.github/prompts/`.

## Build & validate (no live AWS)
The CLI runs inside Devbox from `cli/`:
- `devbox shell` then `enterpriseclaw -h` — list commands.
- Syntax-check Nushell: `cd cli && devbox run -- nu -c 'source enterpriseclaw'`.
- OpenTofu: `tofu fmt`, `tofu validate`, `tofu plan` (where creds/state allow).
- Manifests: `kubectl --dry-run=client`, `kustomize build`, `helm template`.

A real `init` / `destroy` / `apply` needs the live AWS sandbox and is validation work, not
something to run casually — it spends real cloud resources. Read-only checks against a
running sandbox go through Devbox (`cd cli && devbox run -- <aws|kubectl|argo ...>`).

> Note on subagents: the Claude Code setup fans out to specialist subagents and a
> `manager` orchestrator. The Copilot coding agent runs single-agent — the same
> specialization is delivered through the path-scoped instruction files above (auto-applied
> by file path) and, in VS Code, selectable chat modes under `.github/chatmodes/`.
