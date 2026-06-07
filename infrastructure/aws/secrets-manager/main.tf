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

module "secrets_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"   # ← verify current major on the registry before applying

  name = "${var.cluster_name}-secrets"

  # same policy ARN as before, attached via additional_policy_arns
  additional_policy_arns = {
    secrets = module.secrets_policy.arn
  }

  # set cluster_name once instead of repeating it per association
  association_defaults = {
    cluster_name = "${var.cluster_name}-cluster"
  }

  associations = {
    argo-events-webhook = {
      namespace       = "argo-events"
      service_account = "webhook"
    }
    argocd-git-sa = {
      namespace       = "argocd"
      service_account = "git-sa"
    }
    external-secrets-git-sa = {
      namespace       = "external-secrets"
      service_account = "git-sa"
    }
    external-secrets-controller = {
      namespace       = "external-secrets"
      service_account = "external-secrets"
    }
  }

  tags = {
    OpenTofu    = "true"
    Environment = "dev"
  }
}