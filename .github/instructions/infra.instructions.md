---
applyTo: "infrastructure/aws/**,cli/infra/vars.nu"
description: EnterpriseClaw AWS IaC (OpenTofu) — VPC/EKS/DNS/ECR/S3/Secrets Manager.
---

# AWS infrastructure (`infrastructure/aws/`, `cli/infra/vars.nu`)

You own the IaC substrate under `infrastructure/aws/`, written in **OpenTofu** and applied
by the CLI.

## Hard rules
- **AWS only.** `azure`/`gcp` are aspirational — don't design or build for them unless the
  user explicitly asks. The real target is the AWS happy path.
- **Reuse before you write.** Before introducing ANY new resource, **search the Terraform
  Registry** (registry.terraform.io) for an existing, well-maintained module (prefer
  `terraform-aws-modules/*` and official providers) and adapt it to this repo's
  conventions. Hand-rolling raw `resource` blocks is the exception — say so explicitly when
  you go that route. Confirm the module's latest version and inputs/outputs, and **pin it**.

## Layout (read the neighbors before editing)
Modules: `bootstrap/` (state backend, only with `--persistant-state`), `network/` (VPC),
`cluster/` (EKS), `dns/` (Route53/ACM), `image-registries/` (ECR), `pipe-storage/` (S3),
`secrets-manager/`. These use **both IRSA and EKS Pod Identity** depending on the workload —
match that pattern when granting cluster workloads AWS access. The `cluster` module also
provisions the `aws-ebs-csi-driver` addon + IRSA + a default `gp3` StorageClass.

## Conventions & known fragilities
- **tfvars are generated, never hand-edited.** Values come from `cli/infra/vars.nu` (reads
  `$env.*`). If you add a Terraform `variable`, you must also add its generation in
  `cli/infra/vars.nu` — keep the two in sync (flag the CLI-side change if you don't make it).
- **Secrets: read-reference vs auto-create.** Externally-managed SM secrets (`github-creds`,
  `webhook-creds`, `google-idp`, `github-readonly-token`) are read-referenced via
  `secrets_registries` in `vars.nu`; the `secrets-manager` **read policy is scoped to EXACT
  ARNs**, so any SM key an ExternalSecret reads MUST be in `secrets_registries` or created
  by the module — else ESO returns `could not get secret data from provider`. The module
  now *creates* the `keycloak-internal` secret (needs SM write perms:
  `CreateSecret`/`PutSecretValue`/`TagResource`/`DeleteSecret`).
- Apply/destroy consistently use `-exclude=aws_route53_record.acm_config` — an ACM
  DNS-validation **ordering workaround**. Preserve it; reason about ordering if you touch
  DNS/ACM.
- **Image-registry teardown is commented out** (`#containers destroy all … (REVIEW)`) — be
  careful new registries don't leak on destroy.
- ArgoCon prereqs you may add: **Bedrock model access** + `bedrock:InvokeModel` for the
  agentgateway ServiceAccount via **IRSA**; an **S3 bucket for Argo Workflow archive
  artifacts**. Crossplane will later need an AWS provider + IAM (Redis/ElastiCache vs
  Postgres/RDS — TBD).
- Validate with `tofu fmt`, `tofu validate`, `tofu plan` where creds/state allow. A real
  `apply`/`destroy` against the live sandbox is separate validation work.

## Constraints
- **Never reproduce secret values** (tfvars secrets, access keys, `*.pem`) — name keys only.
- **Pin module and provider versions;** don't float to `latest`.
- Stay in your lane: CLI dispatch → cli area; GitOps manifests → gitops area; action images
  → actions area. Always flag the `cli/infra/vars.nu` linkage.
