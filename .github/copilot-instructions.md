# EnterpriseClaw — GitHub Copilot instructions

These are the repository-wide instructions for GitHub Copilot (Chat, agent mode, and
the coding agent). They mirror the project's Claude Code setup (`.claude/CLAUDE.md`,
`.claude/agents/`, `.claude/skills/`). When a task falls into a specific area, the
matching **path-scoped instructions** under `.github/instructions/` auto-apply on top
of this file; the **prompt files** under `.github/prompts/` (`/kagent-trio`,
`/session-broker`, `/slack-integration`, `/docs`) pull in deep references on demand.

## What this project is

**EnterpriseClaw** lets a company build its own security-hardened AI assistant inside a
regulated corporate environment (based on [OpenClaw](https://openclaw.ai/)). Users give
it orders from **Slack** (or Teams). It ships as a **Nushell CLI** (`enterpriseclaw`, run
in **Devbox**) that goes zero-to-running: **OpenTofu** IaC on **AWS/EKS** → a **GitOps**
toolkit that hands off to **Argo CD** (app-of-apps) → **Argo Events + Argo Workflows**
turn each inbound chat message into a short-lived run → the **kagent trio** (kagent + kmcp
+ agentgateway) runs the agent and its MCP tools on **Istio ambient** → the agent opens a
**PR** carrying a **Crossplane** Claim → Argo CD syncs → Crossplane reconciles real infra.

Three sections: **CLI** (`cli/`, the heart), **IaC** (`infrastructure/aws/`, OpenTofu),
and the **GitOps toolkit** (`gitops/` public framework + a per-tenant private repo).

### Near-term goal
Prepare a **talk + demo for ArgoCon Japan** (target ~July 2026). Favor a reliable,
demoable slice that resonates with an Argo / GitOps / cloud-native audience. Longer term:
scale into an OSS framework for AI-agent orchestration in regulated enterprises.

## The thesis (say it this way)

**AI proposes; a governed, auditable GitOps pipeline disposes.** An agent can *reason*
about what to build, but every privileged action flows through the same Argo/GitOps
controls a regulated enterprise already trusts.

**The model is not the security boundary — the service mesh is.** Reachability of any
agent / MCP / tool is decided by **workload SPIFFE identity (ztunnel, L4)** + **Keycloak
JWT claims (agentgateway, L7 waypoint)**, never by the LLM's reasoning. Design so a
prompt-injected agent still cannot reach anything its identity is not allow-listed for.

Two identity rails: **user identity** = Keycloak **JWT**; **workload identity** = ambient
mesh **SPIFFE/mTLS**. JWT propagation (`kagent → agentgateway → MCP`) is a hard
requirement and is upstream of enforcement — a tokenless privileged tool call must be
rejected. See `/session-broker` and `/kagent-trio`.

## Decided demo architecture (the spine)

Slack → Istio gateway → **Argo Events Slack EventSource** → Sensor → **Argo Workflow**
(one short-lived run *per message*) → **Step 0: resolve the human's identity** via the
Session-Broker reader (`POST /identity/resolve`) → the `enterpriseclaw` CLI acts as an
**A2A client**, attaches the user JWT, and calls **agentgateway** → agentgateway validates
the Keycloak JWT (JWKS) **and** authorizes on workload SPIFFE **and** JWT claims → routes
to **kagent** → the agent reasons on **Claude via AWS Bedrock** (called *through*
agentgateway as the LLM gateway; Bedrock IRSA on agentgateway's SA; Guardrails at
`InvokeModel`) → calls tools via **agentgateway MCP federation, forwarding the same user
JWT** → the **kmcp-managed GitHub MCP** opens a **PR** → reply posted to Slack → human
merges → **Argo CD** syncs → **Crossplane** reconciles the Claim.

Conversation state is **stateless / per-message**: it lives in **Slack thread history**
(rebuilt each turn via `conversations.replies`), not in a suspended workflow. The
no-token path hits a **login wall** conditional on *intent* (privileged action ⇒ broker
`/auth/login/start`); an unauthenticated user reaches only a **toolless triage agent** and
a physically `--read-only` issues MCP — the entire anonymous blast radius.

## Current status — be honest, never overclaim

**Built & working:** the AWS happy path end-to-end — CLI `init`/`destroy` for AWS + GitHub
+ Argo CD + `push` mode; all OpenTofu modules; kube-tools patching; app-of-apps; the
GitHub-push → Argo Events → Workflows → git-clone chain; both vendored action images. The
**Slack door is LIVE incl. the agent middle** (triage → read-only answers → login wall
with Google federation). Bedrock LLM hop is green on the IRSA rail.

**Net-new / not-yet-green:** the `act` → `platform-agent` write branch (needs its
`mcp-discovery-token` Secret), archive/artifacts, **Crossplane**, **Kyverno**. Multi-cloud
/ multi-git (`azure`/`gcp`/`gitlab`) and `gitops-setup=pull` (PR mode) are flag stubs with
no implementing code. `cli/containers/main.nu` sources a non-existent `cli/aws/` (broken).

Before asserting a capability or a "done" status, check the relevant area file or skill —
a lot is decided-but-unimplemented or dry-run-only.

## Working agreements (non-negotiable)

- **AWS is the real target.** Don't design for azure/gcp/gitlab in the near term
  (aspirational only). Only build PR mode / other clouds when explicitly asked (the ArgoCon
  demo *does* require building out PR mode).
- **The model is not the security boundary — the mesh is.** (See thesis.)
- **Never reproduce secret values** (`cli/.env`, `*.pem`, tfvars secrets, tokens) in code,
  comments, or output — describe keys/fields by name only.
- **Sandbox values are intentional.** Hardcoded tenant identifiers in the public repo
  (e.g. `grupobancolombia-innersource`, `events.devexp-bancol.com`) and credential-shaped
  `cli/.env` values are throwaway sandbox data — **do not re-flag them as a live leak.**
  Don't add *new* tenant-specific values to the public repo; parameterize instead.
- **Evolve via Issues → PRs, using the `.github/` templates.** Post-MVP work is filed as a
  GitHub Issue (**capability** / **bug** / **spike** forms) and fulfilled by a PR that
  links `Closes #<issue>`. The PR template is dual-use: fill the block above the `---`
  divider (Closes # / Area / what+why / verification evidence) with a signal from a **LIVE
  env, not "it builds"**; the reviewer gates below the divider are status honesty, secret
  hygiene, mesh impact, teardown. The **Area** dropdown (cli / infra / gitops / actions /
  agentic / identity / docs) mirrors the specialist areas — route work from the Area field.
- **tfvars are generated, never hand-edited** (`cli/infra/vars.nu`).
- **Public vs private repo split.** Public `gitops/` = tenant-agnostic framework; the
  private repo = per-tenant data (infra IDs, AWS-specific External-Secrets/ClusterSecretStore).
- **Secrets: read-reference vs auto-create.** Externally-managed SM secrets are
  read-referenced via `secrets_registries` (`cli/infra/vars.nu`) — the read policy is
  scoped to EXACT ARNs, so any key an ExternalSecret reads MUST be registered or created by
  the module. Platform-internal secrets are `random_password`-generated into the single SM
  secret `keycloak-internal`.
- A **Stop hook auto-commits every turn** in the Claude setup; when working here, don't add
  redundant commit/push instructions to code.

## Known fragilities (be careful)

- Teardown uses a hardcoded `sleep 120sec` instead of a readiness poll.
- The GitOps tree has **no sync-wave annotations** despite real dependencies
  (ClusterSecretStore → ExternalSecrets, istiod → gateways) — a source of flaky installs.
- ApplicationSet **child-name collisions cascade-prune** (the installer that installs an
  AppSet must not share the AppSet child's name — e.g. `session-broker-bootstrap`, not
  `session-broker`).
- Infra apply/destroy use `-exclude=aws_route53_record.acm_config` (ACM ordering workaround).
- Recreating the full stack can exceed per-node pod density ("Too many pods" — VPC-CNI ENI
  limit, not CPU/mem).

## Names to get right (don't mangle)

**kagent trio** = **kagent** (Agent + ModelConfig CRDs, A2A server) · **kmcp** (controller
+ MCPServer CRD that runs MCP servers on-cluster) · **agentgateway** (L7 data plane: A2A
routing, MCP federation, JWT/authz; deployed as the Istio ambient L7 waypoint; also the LLM
gateway to Bedrock). **ztunnel** = L4 mTLS/SPIFFE. Argo family: **Argo CD** (app-of-apps),
**Argo Events** (EventSource + Sensor), **Argo Workflows** (per-message run + Archive).
It's **Claude on AWS Bedrock**, **Istio ambient** (not sidecar), **OpenTofu** (not
"Terraform"), **Nushell** CLI in **Devbox**, **Crossplane**, **Keycloak** (Google-federated)
+ **Redis/Dapr** (Session-Broker's stack).

## Where things live / who owns what

| Area | Path | Auto-applied rules | Chat mode / prompt |
|---|---|---|---|
| CLI (Nushell) | `cli/**` | `.github/instructions/cli.instructions.md` | `cli-coder` mode |
| AWS IaC (OpenTofu) | `infrastructure/aws/**`, `cli/infra/vars.nu` | `.github/instructions/infra.instructions.md` | `infra-agent` mode |
| GitOps / Argo manifests | `gitops/**` | `.github/instructions/gitops.instructions.md` | `gitops-agent` mode |
| Action images | `actions/**` | `.github/instructions/actions.instructions.md` | `actions-coder` mode |
| Orchestration / planning | (cross-area) | — | `manager` mode |
| Live-sandbox validation | (read-only) | — | `testing-agent` mode |
| kagent trio deep ref | — | — | `/kagent-trio` |
| Identity / OAuth / broker | — | — | `/session-broker` |
| Slack door / Argo round-trip | — | — | `/slack-integration` |
| Docs (Docusaurus) | `docs/**` | — | `/docs` |

Deep, version-pinned mechanism detail lives in the `.claude/skills/**` reference docs; the
prompt files above point Copilot at them. Read the matching area file before editing, and
stay in your lane — flag cross-cutting needs rather than reaching into another area.
