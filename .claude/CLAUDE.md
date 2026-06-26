# 1. Introduction

We're building the **EnterpriseClaw** project! It helps its users build their own AI Assistant within a corporate environment. It is designed with security principles at its core so it can work in heavily regulated enterprises, and it's based on [OpenClaw](https://openclaw.ai/)'s AI Assistant. The assistant receives orders from its users through any corporate chat platform (initial intended support: Microsoft Teams and Slack) and their company's IDP (_Internal Developer Platforms_).

The project has three main sections:
1. **CLI** — runs in the terminal as the `enterpriseclaw` command. It's the core of the project: it goes from zero to a fully running AI assistant platform on Kubernetes with a handful of commands.
2. **IaC** — a (currently AWS-only) infrastructure layer that provisions the substrate.
3. **GitOps toolkit** — automates the platform setup inside the corporate infrastructure via Argo CD.

## 1.1. CLI

A single executable, `enterpriseclaw`, written in **Nushell** and run inside a **Devbox** environment. Devbox pins the toolchain (nushell, opentofu, kubectl, helm, argo, awscli, gh) and loads config from `cli/.env` via `env_from`, so the CLI reads configuration from `$env.*` rather than from its own flags. The entrypoint ([cli/enterpriseclaw](../cli/enterpriseclaw)) is a thin (~80-line) orchestrator; all real logic lives in sourced modules under [cli/](../cli/) (`infra/`, `cluster/`, `kube-tools/`, `gitops/`, `git/`, `containers/`, `utils/`).

## 1.2. IaC

Runs **OpenTofu** ([infrastructure/aws/](../infrastructure/aws/)) to create the VPC, EKS cluster, DNS zones (Route53/ACM), image registries (ECR), blob storage (S3), and Secrets Manager entries. It reads the user's environment (region, company name, domain, GitHub App credentials) from `.env` and **generates the tfvars automatically** (`cli/infra/vars.nu`) so users never touch a Terraform variable file by hand.

## 1.3. GitOps Toolkit

Authenticates to the git provider, clones the user's GitOps config repo, and patches the Kubernetes manifests with live infra outputs (ALB controller role ARN, certificate ARN, hosted zone IDs, nodegroup labels) so Argo CD can apply them cleanly on first boot. It is made of **two repositories**:

1. **Public source** — the general framework every private project builds on. URL: https://github.com/jdarguello/EnterpriseClaw (lives in this repo under [gitops/](../gitops/)).
2. **Private repo** — the user's own repository for private configuration with their infrastructure data. It is the Argo CD app-of-apps root; the CLI vendors a clone at [cli/gitops-config/](../cli/gitops-config/) (a nested git repo, gitignored).

---

# 2. Goals & Roadmap

Two goals drive the work:
1. **Near-term:** prepare a **talk + demo for ArgoCon Japan**. Favor a reliable, demoable slice that resonates with an Argo / GitOps / cloud-native audience.
2. **Longer-term:** scale EnterpriseClaw into an **open-source framework for AI Agent Orchestration** in regulated enterprises.

## 2.1. AI Assistant runtime vision (runtime not yet built; ArgoCon demo architecture now decided — see §2.2)

The actual assistant workload is **not in the codebase yet**; today the repo stands up the *platform and CI plumbing*, not the agent. The working (not finalized) vision is a **hybrid topology segmented by user persona / trust zone / blast radius**:

| Tier | Persona | Runtime | Scope |
|---|---|---|---|
| Local | Individual dev | NemoClaw / OpenCode | User's local ecosystem |
| Platform | Platform/SRE | **Kagent** (on-cluster) | k8s orchestration: Platform Engineering Golden Paths + AIOps |
| Functional | Business user (e.g. bank commercial team) | **Dapr Agents** | Durable, data-bound domain workflows |

**Short-term focus:** the **Platform tier** — Kagent driving the existing Argo substrate. This was an open design question; it is now **decided** for the demo (see §2.2). NemoClaw (local), Dapr (functional), and OpenCode general agents are roadmap, **not** demo scope.

## 2.2. ArgoCon demo — decided architecture (target ~July 2026)

The §2.1 open question is **resolved for the demo**. Scenario: a **Golden Path via chat** — a platform engineer asks in **Slack** for a new service + a managed dependency; the agent reasons and **opens a PR** carrying a **Crossplane** Claim; Argo reconciles it into existence. Every piece has documented building blocks (verified against Kagent docs, 2026-06-23).

**Agentic stack = the kagent trio** (decided 2026-06-24): **kagent** (the agent runtime — Agent CRD + ModelConfig + A2A server), **kmcp** (controller + `MCPServer` CRD that *runs* MCP servers on-cluster; "the GitHub MCP server" is now a kmcp-managed `MCPServer`), and **agentgateway** (the L7 data plane *between* the agentic pieces — A2A routing, MCP federation/multiplexing, and security). **agentgateway is deployed as the Istio ambient L7 waypoint and owns L7 security governance**; **ztunnel** provides the L4 mTLS/SPIFFE substrate. Pin all three as one compatible *set* (pre-1.0, versioned together).

**Decided spine:**
> Slack → Istio gateway → **Argo Events Slack EventSource** → Sensor → **Argo Workflow** (one short-lived run *per inbound message*) → **Step 0 — resolve the human's identity: call the Session-Broker reader (`POST /identity/resolve`, header `X-Slack-User-Id`; mTLS-gated so only this workflow-step's SA may call it)** → workflow step (the **`enterpriseclaw` CLI A2A client**, *not* an `actions/` container) sets `Authorization: Bearer <user JWT>` and calls **agentgateway** → **agentgateway (L7 waypoint)** validates the Keycloak JWT (JWKS) and authorizes on workload SPIFFE **and** JWT claims → routes A2A to **Kagent** → agent reasons on **Claude via AWS Bedrock**, called *through* **agentgateway as the LLM gateway** (agentgateway's SA holds the **Bedrock IRSA** role — least privilege; **Guardrails enforced at `InvokeModel`**; this LLM hop is authenticated by workload/IRSA, **not** the user JWT — they are two separate identity rails) → agent calls tools via **agentgateway MCP federation, forwarding the same user JWT** → **kmcp-managed GitHub `MCPServer`** (POC: authenticates to GitHub with **GitHub App creds**, reusing the `create-github-app-token` mint; the user JWT **stops here** — GitHub-side author = bot) → PR opened (mutating ops behind a human-approval prompt) → reply posted back to Slack → human merges → **Argo CD** syncs → **Crossplane** reconciles the Claim → app Deployment (instant) + managed dependency (pre-warmed).

**Key decisions:**
- **Stateless, per-message conversation.** Compute is stateless; conversation state lives in **Slack thread history** (rebuilt each turn via `conversations.replies`), *not* in a long-running/suspended workflow nor Kagent's server-side `contextId`. Multi-turn clarification = the agent posts a question; the next Slack reply fires a fresh workflow. The agent returns **structured output** (`question` / `proposal` / `login-required`) so the Workflow DAG can branch deterministically.
- **A2A client = the `enterpriseclaw` CLI** (decided: option b), *not* an `actions/` image. The workflow step is a new `main …` command that speaks the A2A JSON-RPC `message/send` and attaches the user bearer. (Correction: **A2A is a protocol with SDKs, not a GitHub Marketplace Action** — don't go hunting for a Marketplace action.) The under-documented A2A multi-turn history payload is still a dry-run risk.
- **Change delivery = the agent opens the PR itself** (decided: option A), via the kmcp GitHub MCP (`create_branch` / `create_or_update_file` / `create_pull_request`). This is `gitops-setup=pull`/PR mode — a flag today with **no implementing code** (§4), so it is net-new.
- **Model = Claude on Bedrock *via agentgateway as the LLM gateway*.** agentgateway's ServiceAccount holds the **Bedrock IRSA** role (so *only* agentgateway has `bedrock:InvokeModel` — least privilege), and Kagent's `ModelConfig` points at **agentgateway** rather than at Bedrock directly. **Guardrails attach at the `InvokeModel` call** (not agentgateway prompt-filtering, for now). Account prereqs unchanged: enable Bedrock model access for the Claude model. (Verify pre-1.0: agentgateway's Bedrock provider / SigV4 support + the exact `ModelConfig` endpoint shape.)
- **GitHub auth (POC) = GitHub App creds**, reusing the existing [actions/create-github-app-token](../actions/) mint — so the user JWT governs *whether* the human may invoke the GitHub MCP (agentgateway authz) but does **not** reach GitHub; the commit author is the bot and **human attribution lives in the Argo Workflow archive + agentgateway trace**. Full user-impersonation (a second federated GitHub identity brokered by Session-Broker) is **deferred past ArgoCon**.
- **Demo UX leads with the UIs** — kagent dashboard + agentgateway view + Argo CD + the live Slack thread, *not* a terminal. **No SSO on the demo UIs** (deliberately deferred to the production-hardening pass).
- **Audit story:** every order = an archived Argo Workflow (enable the **Workflow Archive** + write prompt/response/manifest as **artifacts to the provisioned S3 bucket**), plus the PR + git history. Framing: *AI proposes; a governed, auditable pipeline disposes.*

**Identity & authorization — closes the identity gap (Session-Broker, [github.com/jdarguello/Session-Broker](https://github.com/jdarguello/Session-Broker)):**
Without it, every privileged action runs under **static infra identities** (the Bedrock IRSA ServiceAccount + the GitHub-App bot) — no per-human authorization, no human-level audit. The broker binds a `slack_user_id` to a **real corporate identity** (Google Workspace federated behind **Keycloak**) and caches the user's encrypted tokens in Redis via Dapr. It is the **confidential OAuth client** (broker-minted one-time `state` nonce + PKCE; broker performs the `code→token` exchange itself, so cached tokens are provenance-guaranteed Keycloak-issued).
- **Two-identity propagation (the demo's headline), enforced at the agentgateway waypoint.** **User identity** = the Keycloak **JWT**; **workload identity** = the ambient-mesh **SPIFFE/mTLS** principal. The split: **ztunnel** enforces L4 (mTLS + the workload SPIFFE rail); **agentgateway (the L7 waypoint)** validates the JWT (JWKS from Keycloak) and authorizes on `source.principal` (workload) **and** `jwt.claims` (user) — *who **and** what*. **Keycloak authors the authz model**: the JWT carries client-scope / groups / roles / permissions, and **agentgateway translates those claims → which agents / MCPs / tools the human may reach**. The catalog (target → required scope) is **framework-level (public repo)**; the role-to-user assignment is **tenant-side (Keycloak / Session-Broker)**. Istio `AuthorizationPolicy` / `PeerAuthentication` remain available as an *enforcement* fallback (and `PeerAuthentication` is what hard-locks the workload rail). **POC framing (honest):** strong, fine-grained user identity (JWT, scope-by-scope) + a **present-but-coarse** workload identity (ambient auto-mints the SPIFFE principal; a dedicated per-step SA is deferred past ArgoCon). Both rails are visibly on stage.
- **JWT propagation is a HARD REQUIREMENT and is *upstream* of enforcement.** Kagent **must** forward the user bearer to its MCP tool calls; a tokenless privileged tool call must be rejected. **No policy engine — agentgateway *or* Istio — can authorize a token that was never put on the wire** (Istio is an *enforcement* fallback, not a *propagation* fix). This is the **riskiest unknown → dry-run it first** (kind cluster + an "echo" MCP that returns its received headers; assert the user bearer survives `kagent → agentgateway → MCP` intact and pass-through, not re-minted). Fallback ladder if kagent doesn't forward natively: **(1)** kagent header-passthrough config → **(2)** an agentgateway filter re-attaching the session bearer → **(3)** patch/PR kagent → **(4)** restructure so the *workflow* (not the agent) performs the mutating token-bearing step (breaks "the agent decides to call the tool" — last resort). **DRY-RUN UPDATE (2026-06-25): the kagent hop is de-risked — fallback step 1 WORKS.** kagent forwards the inbound bearer to MCP intact via `Agent.declarative.tools[].mcpServer.allowedHeaders: ["Authorization"]` (iteration 1 passed, kagent→MCP-direct). The `kagent → agentgateway → MCP` hop is iteration 2: **stage A (bearer survives the L7 hop) ✅ PASSED 2026-06-25** — repointed kagent's `RemoteMCPServer` through an agentgateway proxy (`Gateway` class `agentgateway` → `AgentgatewayBackend` kind mcp → `HTTPRoute` → `AgentgatewayPolicy`); echo-MCP received the bearer intact. **Surprise: for MCP backends agentgateway forwards `Authorization` by DEFAULT** — `backend.auth.passthrough` is NOT required (it's for *injecting* upstream creds, e.g. the LLM-gateway Bedrock SigV4 path); proven by a negative control (policy deleted, bearer still arrived). **Stage B (agentgateway validates the Keycloak JWT + claim-gates) ✅ PASSED 2026-06-25** — provisioned an `enterpriseclaw` realm (role `mcp-user`, users alice=role/bob=no-role) and drove the gateway's MCP endpoint with real RS256 tokens: **alice → echo runs; bob → 403; no-token → 401; forged → 401 InvalidSignature.** agentgateway validated signature (remote Keycloak JWKS) + issuer + audience and claim-gated on the realm role — the headline "Keycloak claims → which MCP/tool, enforced by the mesh not the model." 1.3.1 gotchas that shaped the working config: validation+authz must BOTH be `traffic.*` (route-level) with `jwtAuthentication.mode: Strict` (Strict alone populates `jwt.*` for the CEL); `backend.mcp.authentication` is unusable (NACKs for `jwks_inline`); the validated bearer is consumed at the gateway unless `backend.auth.passthrough`. **Open integration item:** end-to-end *through kagent* needs the controller's tokenless tool-discovery to survive `Strict` (give `RemoteMCPServer.headersFrom` a discovery token). Details: the `kagent-trio` skill's `jwt-propagation.md` + `crds.md`.
- **Per-message branch (Step 0).** **Token found** → carry the user JWT into the A2A call (spine above). **No token** → the **JWT-less door**, reachable on **workload identity alone**, in two parts: **(a)** a **toolless triage agent** (`general-classifier`) with **no MCP permissions** — its SPIFFE principal is in no MCP's allow-list, so mTLS refuses it at the identity layer (*even fully prompt-injected it cannot reach a tool*); it only decides intent. **(b)** for **informational** intent it routes to a **read-only reader** (`github-reader`), whose **sole** tool is a **physically `--read-only`** GitHub **issues** MCP (`github-readonly`) — zero write tools are registered, it is reached **directly** on the workload rail (no agentgateway hop, no user JWT), and its dedicated read-scoped token is the entire anonymous blast radius. So the unauth door can *answer* (read issues) but still cannot mutate or reach the Strict-gated write MCPs. **Privileged action implied** → call the broker **writer** `POST /auth/login/start` → post the returned Keycloak `/authorize` URL to Slack → end the run. The next Slack reply re-fires a fresh workflow with the token now cached. The login wall is **conditional on intent**, not on mere auth state — agentgateway requiring a JWT on every *privileged* target is what forces it. **The model is not the security boundary — the mesh (and, on the anonymous path, the `--read-only` tool surface) is.** (Read-only scope is **issue-reading only for now**; extending to PRs = add `pull_requests` to `github-readonly` + the PR tools/skill to `github-reader`.)
- **Ownership boundary.** **Keycloak + Redis + Dapr and the OAuth write/read paths live in the Session-Broker repo, not here** (the Keycloak helm-app left this repo in `796d38e`). EnterpriseClaw owns Argo Events/Workflows, Istio, **the kagent trio (kagent + kmcp + agentgateway)**, Crossplane, and the **agentgateway authz policy** (the enforcement plane). The agent calls the broker, **never Keycloak directly** — the broker is the only component that touches Keycloak on the write path.
- **`aud` handling (decided for POC):** a **single broad audience** (e.g. "the agents"), validated by agentgateway at each hop. **Per-agent token exchange is the hardening path**, deferred past ArgoCon.

**Build phases** (do P0 first — riskiest unknown): **P0** install the **kagent trio** (kagent + kmcp + **agentgateway as the ambient L7 waypoint**, pinned as a set) + `ModelConfig` pointing at **agentgateway as the LLM gateway** (Bedrock IRSA on the agentgateway SA) + **prove JWT propagation `kagent → agentgateway → MCP`** (the long pole — see Identity section) · **P1** wire the kmcp GitHub `MCPServer` + test the PR-open path end-to-end · **P2** Crossplane + AWS provider + a minimal **XRD/Composition** Golden Path, landing where an ApplicationSet globs it · **P3** stitch Slack↔Workflow↔agent + **Session-Broker Step 0 (`/identity/resolve`) + the no-token login-wall (`/auth/login/start`) + agentgateway JWT/claims authz enforcement** + archive/artifacts + pre-warm the slow managed dependency.

**Dry-run before stage** (the real reliability risks, riskiest first): **(1) JWT propagation** — kind cluster + an echo MCP, assert the user bearer survives `kagent → agentgateway → MCP` intact (and isolate the hop if it doesn't); **(2)** the GitHub-MCP PR path (kagent issue **#976**); **(3)** the A2A multi-turn history payload (under-documented); **(4)** agentgateway's Bedrock provider / SigV4 + the Bedrock model-access toggle; **pin the kagent + kmcp + agentgateway versions as one compatible set** (CNCF Sandbox, pre-1.0 — API churn, e.g. ToolServer→kmcp).

**Still TBD (secondary):** managed dependency = Redis (ElastiCache) vs Postgres (RDS); exact XRD/Composition shape (lean: real but minimal); human merges the PR live on stage (lean: yes).

---

# 3. End-to-end flow

All driven by `main init` / `main destroy` in [cli/enterpriseclaw](../cli/enterpriseclaw). Nushell **multi-word command names** (`main cluster setup`, `main init gitops argocd`, …) are the dispatch mechanism, resolved across the sourced module files.

**`main init` (zero-to-running):**
1. **IaC** — optional `main cluster bootstrap` (state backend, only if `--persistant-state`), then `main cluster setup` → `tofu apply` of VPC/EKS/DNS/ECR/S3/Secrets (tfvars generated from `$env.*`).
2. **Connect** — `main cluster connect` → `aws eks update-kubeconfig` for `<cluster-name>-cluster`.
3. **kube-tools** — `main kube-tools bootstrap`: `rm -rf gitops-config/`, clone the private repo, patch it with live `tofu output` + nodegroup labels (ALB controller, external-dns, External-Secrets SA, Istio, Argo events/workflows IRSA SAs), then `git push` if `--gitops-setup=push`.
4. **Argo CD** — `main init gitops argocd`: Helm-install Argo CD, install External-Secrets Operator, then `kubectl create -f gitops-config/main.yaml` to hand off to the app-of-apps.

**Argo CD app-of-apps:** the private repo's `main.yaml` renders children — an ApplicationSet `helm` (helm/*), an Application `helm-istio` (kept as a single atomic unit, deliberately not an ApplicationSet), and an ApplicationSet `configs` (config/*). Each child **remote-references the public repo at `?ref=main`** and overlays it with tenant values (Argo multi-source `$values` for Helm; Kustomize patches for config). Secrets resolve at runtime via External-Secrets + an AWS Secrets Manager `ClusterSecretStore` (keys `github-creds`, `webhook-creds`).

**Realized "order" path:** GitHub `push` webhook → ALB Ingress → Istio gateway/VirtualService → Argo Events EventSource → NATS EventBus → Sensor → Argo Workflow → git-clone via a minted GitHub-App token.

**`main destroy`:** connect → `main teardown gitops` (delete Argo `main` App, `configs` ApplicationSet, `helm-istio` App) → hardcoded `sleep 120sec` → `main destroy infra` (`tofu destroy`).

---

# 4. Current implementation status

**Built & working (AWS happy path is end-to-end):** CLI `init`/`destroy` for **AWS + GitHub + Argo CD + push** mode; Devbox toolchain; all OpenTofu modules (bootstrap, network, cluster, dns, image-registries, pipe-storage, secrets-manager) with IRSA + EKS Pod Identity; kube-tools patching; Argo CD app-of-apps; the full GitHub-push → Argo Events → Argo Workflows → git-clone chain; both vendored action images ([actions/](../actions/) checkout + create-github-app-token).

**WIP / stubbed / broken:**
- The **agentic workload now EXISTS in GitOps** (no longer absent): an **`agentic` ApplicationSet** globs [gitops/agentic/](../gitops/agentic/) into four apps — **agents** (`general-classifier` toolless triage, `platform-agent` action agent, `github-reader` unauth read-only issues reader), **mcps** (kmcp `MCPServer`s — `github-issues` + `infra-provisioning` write-path, plus `github-readonly` `--read-only` **issues** for the unauth reader), **mcp-gateway** (agentgateway Strict-JWT + capability-CEL routes), **llm-gateway** (Bedrock `ModelConfig`). **Proven on the dry-run VM (2026-06-26):** tool discovery through the Strict agentgateway (workload-token rail) and the **read-only issues path live** (`--read-only` registers issue reads only — `issue_read`/`list_issues`/`search_issues`/`list_issue_types`/`get_label` — **zero write tools**); all Agents/MCPServers `Ready`. Still **net-new**: the **A2A client (in the `enterpriseclaw` CLI)**, the Slack↔Workflow↔agent stitch + archive/artifacts, Crossplane, and **Kyverno** (decided-but-unimplemented). Install scaffolding under [gitops/helm/agents/](../gitops/helm/agents/) — `kagent`+`kagent-crds` (0.9.9), standalone `kmcp`+`kmcp-crds` (0.3.0), `agentgateway`+`agentgateway-crds` (`cr.agentgateway.dev/charts` @ 1.3.1, ns `agentgateway-system`, `istio.autoEnabled: true`). Specifics in the [kagent-trio skill](skills/kagent-trio/).
- **Multi-cloud / multi-git is aspirational** — `azure`/`gcp`/`gitlab` and `gitops-setup=pull` (PR) are flag options with no implementing code. `secret-provider` only handles `cloud`.
- **Keycloak/OIDC moved out of this repo** — the previously-broken Keycloak helm-app (a verbatim copy of the argo-events app) was **removed in `796d38e`**; identity now lives in the **Session-Broker** repo, which owns Keycloak + Redis + Dapr + the OAuth write/read paths (Google federation behind Keycloak). EnterpriseClaw's remaining identity work is the **consumer side** (see §2.2): Workflow Step 0 (`/identity/resolve`), the no-token login-wall (`/auth/login/start`), and the **agentgateway L7 waypoint authz** (Keycloak-claim → agent/MCP/tool mapping; Istio `AuthorizationPolicy`/`PeerAuthentication` as fallback) — none of which is implemented yet.
- **Container/ECR build path is broken** — [cli/containers/main.nu](../cli/containers/main.nu) does `source ../aws/ecr.nu`, but `cli/aws/` does not exist.
- Build/sonar/test Argo Workflow templates exist but **only `git-clone` is wired** into the pipeline.
- Docs are unmodified Docusaurus scaffold; top-level README install sections are empty.

---

# 5. Conventions & patterns

- **Nushell multi-word commands** for dispatch; config comes from `$env.*` (Devbox `env_from` of `cli/.env`), not CLI flags.
- **tfvars are generated**, never hand-edited (`cli/infra/vars.nu`).
- GitOps overlays **remote-reference the public repo** and patch it per-tenant — the CLI's real job is generating the private repo's overlays from live infra and applying its root Application.
- AWS identity uses **both IRSA and EKS Pod Identity** depending on the workload.
- Service mesh is **Istio ambient** — **ztunnel** at L4 (mTLS / SPIFFE) + **agentgateway as the L7 waypoint** for agent/MCP/A2A traffic (auth + tool-level authz); security-shaped node placement (tainted `role=frontend` public nodegroup for edge workloads, private nodegroups for controllers/backends).
- **agentgateway is installed from its upstream Helm chart** (`cr.agentgateway.dev/charts` @ 1.3.1), which is a **kgateway-derived Gateway-API control plane** — so the K8s **Gateway API is its config API and is always used**; it is *not* an alternative to Istio, and there is no value to "turn it off." The Istio knob is **`istio.autoEnabled: true`** = mesh-integrate the proxies it provisions (the §2.2 waypoint: SPIFFE/mTLS from istiod + JWT at L7). **Istio stays the sole `gateway.networking.k8s.io` CRD owner** (the `agentgateway-crds` chart ships only `agentgateway.dev` CRDs — no collision). Prereqs to deploy the chart at all: the Gateway-API CRDs present (Istio supplies them in prod; the dry-run VM installs them via [gitops/dry-run/gateway-api-crds.yaml](../gitops/dry-run/gateway-api-crds.yaml)) + istiod for *meshed* gateways (the controller stays Ready without it until a meshed Gateway is created).

---

# 6. Known fragilities (be careful here)

- Teardown relies on a **hardcoded `sleep 120sec`** instead of a reconciliation/readiness poll.
- The GitOps tree has **no sync-wave annotations** despite real dependencies (ClusterSecretStore → ExternalSecrets, istiod → gateways) — a likely source of flaky installs/destroys.
- Image-registry teardown is commented out (`#containers destroy all … (REVIEW)`).
- Infra apply/destroy consistently use `-exclude=aws_route53_record.acm_config` (ACM DNS-validation ordering workaround).

---

# 7. Working agreements

- **AWS is the real target.** Don't design for azure/gcp in the near term (aspirational only).
- **Sandbox values are intentional.** The hardcoded tenant identifiers in the public repo (e.g. `grupobancolombia-innersource`, `events.devexp-bancol.com` in [gitops/config/argo-events/event-source.yaml](../gitops/config/argo-events/event-source.yaml)) and the credential-shaped values in `cli/.env` are throwaway sandbox data — **do not keep re-flagging them as a live security leak.** (Parameterizing tenant values out of the *public* framework is still worth doing once, before the eventual OSS release.)
- **Never reproduce secret values** (`.env`, `*.pem`, tfvars secrets) in output — describe keys/fields only.
- Lead the ArgoCon demo with the **kagent trio (kagent + kmcp + agentgateway) driving the existing GitOps/Argo pipeline** per the decided architecture in **§2.2**; keep NemoClaw/Dapr/OpenCode as roadmap.
- **The model is not the security boundary — the mesh is.** Reachability of any agent/MCP/tool is decided by workload SPIFFE (ztunnel) + Keycloak JWT claims (agentgateway), never by the LLM's reasoning; design so a prompt-injected agent still cannot reach anything its identity isn't allow-listed for.

---

# 8. Local dev / run

The CLI runs inside Devbox from [cli/](../cli/):
- `devbox shell` (init_hook makes `enterpriseclaw` executable, adds it to PATH, and drops into `nu`).
- `enterpriseclaw -h` — list commands.
- `enterpriseclaw init` — zero-to-running (flags: `--cloud-provider`, `--cluster-name`, `--secret-provider`, `--git-provider`, `--persistant-state`, `--gitops-agent`, `--gitops-setup`).
- `enterpriseclaw destroy` — teardown (ideal for ephemeral environments).

Required `.env` keys include: `region`, `COMPANY_NAME`, `ORG_NAME`, `CONFIG_REPO`, `BRANCH_NAME`, `domain_name`, `argocd_version`, `GIT_USER`, `GIT_USER_EMAIL`, `GH_TOKEN`, `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_CLIENT_SECRET`, `github_app_registry`, `github_webhook_registry`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`.
