---
applyTo: "cli/**"
description: EnterpriseClaw Nushell CLI — the heart of the framework.
---

# CLI work (`cli/`)

The `enterpriseclaw` CLI is a single **Nushell** executable run inside **Devbox**; it goes
from zero to a running AI-assistant platform on Kubernetes. Most of the framework's real
logic lives here — including operations that Argo Workflow containers invoke. **Design
principle: workflow steps are thin containers that call `enterpriseclaw`** (e.g. "call the
agent", "open a PR") rather than embedding logic in YAML. Generic, non-project-specific
operations belong in `actions/` instead (see the actions rules).

## Architecture & conventions (follow exactly)
- **Entrypoint:** `cli/enterpriseclaw` is a thin (~80-line) orchestrator that `source`s
  modules. Real logic lives in module files under `cli/`: `infra/`, `cluster/`,
  `kube-tools/`, `gitops/`, `git/`, `containers/`, `utils/`, `slack/`. **Read the
  entrypoint first** to see what's already sourced.
- **Dispatch via Nushell multi-word command names:** `def --env "main cluster setup" [...]`,
  `def "main init gitops" [...]`. A new capability = a new `main <words>` def in the right
  module, plus sourcing the module in the entrypoint if it's a new top-level verb.
- **Config comes from `$env.*`, not flags.** Devbox `env_from` loads `cli/.env` into the
  environment; the CLI reads `$env.region`, `$env.COMPANY_NAME`, etc. Flags are reserved
  for the `init`/`destroy` options (`--cloud-provider`, `--gitops-setup`, …). Don't invent
  new required `.env` keys without flagging it for the README / `.env` template.
- **tfvars are generated, never hand-edited** — that lives in `cli/infra/vars.nu`. If a CLI
  change needs a new Terraform variable, generate it there (and keep it in sync with the
  infra layer).
- **AWS is the real target.** `azure`/`gcp`/`gitlab` and `secret-provider` beyond `cloud`
  are aspirational flag stubs — don't build them unless asked. `gitops-setup=pull` (PR
  mode) has **no implementing code** and is net-new work per the ArgoCon plan.
- Devbox pins the toolchain (nushell, opentofu, kubectl, helm, argo, awscli, gh) — assume
  those are the only CLIs available at runtime.

## How to work
1. Read the relevant module(s) + the entrypoint before editing; mirror the existing
   Nushell style (multi-word defs, `--env` where state must propagate, `$env.*` config;
   some in-code comments are Spanish — match the file).
2. Make the smallest change that fits the existing dispatch pattern. Keep the entrypoint
   thin; put logic in modules.
3. **Validate syntax:** `cd cli && devbox run -- nu -c 'source enterpriseclaw'` catches
   parse errors. A full `init`/`destroy` needs live AWS — that's live-sandbox validation,
   not a casual run.
4. Beware the known fragilities: teardown `sleep 120sec` (no readiness poll), missing
   sync-wave ordering, the **broken** `cli/containers/main.nu` (`source ../aws/ecr.nu` — the
   `cli/aws/` dir does not exist), and ACM `-exclude=aws_route53_record.acm_config`
   workarounds. If you touch these, note the risk.

## Constraints
- **Never reproduce secret values** from `cli/.env`, `*.pem`, or tfvars — name keys/fields
  only.
- Stay in your lane: GitOps YAML → gitops area; Terraform → infra area; generic action
  images → actions area. If a CLI change implies work there, call it out.
