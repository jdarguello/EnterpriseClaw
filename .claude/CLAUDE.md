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

**Decided spine:**
> Slack → Istio gateway → **Argo Events Slack EventSource** → Sensor → **Argo Workflow** (one short-lived run *per inbound message*) → step calls **Kagent** over **A2A** (HTTP `:8083`, via an A2A-client container in the `actions/` pattern) → agent reasons on **Claude via AWS Bedrock** (auth: **EKS IRSA** on its ServiceAccount) → agent **opens a PR to the private gitops repo via the GitHub MCP server** (mutating ops behind a human-approval prompt) → reply posted back to Slack → human merges → **Argo CD** syncs → **Crossplane** reconciles the Claim → app Deployment (instant) + managed dependency (pre-warmed).

**Key decisions:**
- **Stateless, per-message conversation.** Compute is stateless; conversation state lives in **Slack thread history** (rebuilt each turn via `conversations.replies`), *not* in a long-running/suspended workflow nor Kagent's server-side `contextId`. Multi-turn clarification = the agent posts a question; the next Slack reply fires a fresh workflow. The agent returns **structured output** (`question` vs `proposal`) so the Workflow DAG can branch deterministically.
- **Change delivery = the agent opens the PR itself** (decided: option A), via GitHub MCP (`create_branch` / `create_or_update_file` / `create_pull_request`). This is `gitops-setup=pull`/PR mode — a flag today with **no implementing code** (§4), so it is net-new.
- **Model = Claude on Bedrock via IRSA.** Account prereqs: enable **Bedrock model access** for the Claude model; grant `bedrock:InvokeModel`. (`ModelConfig` `provider: Bedrock` + `bedrock.region`.)
- **Audit story:** every order = an archived Argo Workflow (enable the **Workflow Archive** + write prompt/response/manifest as **artifacts to the provisioned S3 bucket**), plus the PR + git history. Framing: *AI proposes; a governed, auditable pipeline disposes.*

**Build phases** (do P0 first — riskiest unknown): **P0** Kagent install + `ModelConfig` (Bedrock) + IRSA role + A2A reachability · **P1** wire the GitHub MCP server + test the PR-open path end-to-end · **P2** Crossplane + AWS provider + a minimal **XRD/Composition** Golden Path, landing where an ApplicationSet globs it · **P3** stitch Slack↔Workflow↔agent + archive/artifacts + pre-warm the slow managed dependency.

**Dry-run before stage** (the real reliability risks): the GitHub-MCP PR path (kagent issue **#976**); the exact A2A multi-turn history payload (under-documented); the Bedrock model-access toggle; **pin every Kagent chart version** (CNCF Sandbox, pre-1.0 ~v0.9.x — API churn, e.g. ToolServer→kmcp).

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
- The **AI assistant workload itself is absent** (see §2.1). **Kyverno and Kagent are README-only**, not implemented.
- **Multi-cloud / multi-git is aspirational** — `azure`/`gcp`/`gitlab` and `gitops-setup=pull` (PR) are flag options with no implementing code. `secret-provider` only handles `cloud`.
- **Keycloak is broken** — [gitops/helm/security/keycloak/helm-app.yaml](../gitops/helm/security/keycloak/helm-app.yaml) is a verbatim copy of the argo-events app (it deploys argo-events, not Keycloak). SSO/OIDC is unrealized. (This is the current untracked working-tree change.)
- **Container/ECR build path is broken** — [cli/containers/main.nu](../cli/containers/main.nu) does `source ../aws/ecr.nu`, but `cli/aws/` does not exist.
- Build/sonar/test Argo Workflow templates exist but **only `git-clone` is wired** into the pipeline.
- Docs are unmodified Docusaurus scaffold; top-level README install sections are empty.

---

# 5. Conventions & patterns

- **Nushell multi-word commands** for dispatch; config comes from `$env.*` (Devbox `env_from` of `cli/.env`), not CLI flags.
- **tfvars are generated**, never hand-edited (`cli/infra/vars.nu`).
- GitOps overlays **remote-reference the public repo** and patch it per-tenant — the CLI's real job is generating the private repo's overlays from live infra and applying its root Application.
- AWS identity uses **both IRSA and EKS Pod Identity** depending on the workload.
- Service mesh is **Istio ambient**; security-shaped node placement (tainted `role=frontend` public nodegroup for edge workloads, private nodegroups for controllers/backends).

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
- Lead the ArgoCon demo with **Kagent driving the existing GitOps/Argo pipeline** per the decided architecture in **§2.2**; keep NemoClaw/Dapr/OpenCode as roadmap.

---

# 8. Local dev / run

The CLI runs inside Devbox from [cli/](../cli/):
- `devbox shell` (init_hook makes `enterpriseclaw` executable, adds it to PATH, and drops into `nu`).
- `enterpriseclaw -h` — list commands.
- `enterpriseclaw init` — zero-to-running (flags: `--cloud-provider`, `--cluster-name`, `--secret-provider`, `--git-provider`, `--persistant-state`, `--gitops-agent`, `--gitops-setup`).
- `enterpriseclaw destroy` — teardown (ideal for ephemeral environments).

Required `.env` keys include: `region`, `COMPANY_NAME`, `ORG_NAME`, `CONFIG_REPO`, `BRANCH_NAME`, `domain_name`, `argocd_version`, `GIT_USER`, `GIT_USER_EMAIL`, `GH_TOKEN`, `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_CLIENT_SECRET`, `github_app_registry`, `github_webhook_registry`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`.
