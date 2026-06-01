locals {
  secrets_map = { for s in var.secrets_registries : s.name => s }
  secret_arns = [for s in data.aws_secretsmanager_secret.secrets : s.arn]
}

data "aws_secretsmanager_secret" "secrets" {
  for_each = local.secrets_map
  name     = each.key
}

module "secrets_policy" {
  source = "terraform-aws-modules/iam/aws//modules/iam-policy"

  name        = "secrets-policy"
  path        = "/"
  description = "IAM permissions to read secrets from Secrets Manager"

  policy = templatefile(
    "${path.module}/policies/secrets_policy.tpl",
    { secret_arns = local.secret_arns }
  )

  tags = {
    OpenTofu    = "true"
    Environment = "dev"
  }
}

module "irsa-secrets" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"

  name = "${var.cluster_name}-secrets"

  oidc_providers = {
    cluster_oidc = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["argo-events:webhook", "argocd:git-sa", "external-secrets:git-sa"]
    }
  }

  policies = {
    policy = module.secrets_policy.arn
  }
}