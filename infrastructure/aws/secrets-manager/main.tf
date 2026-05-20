data "aws_secretsmanager_secret" "innersource-webhook-secret" {
  name = var.innersource_webhook_secret_name
}

module "webhook_policy" {
  source = "terraform-aws-modules/iam/aws//modules/iam-policy"

  name        = "webhook-policy"
  path        = "/"
  description = "Permisos IAM que permite obtener valores del secreto del InnerSource-Webhook-Secret en Secrets Manager"

  policy = templatefile(
    "${path.module}/policies/innersource_app_secret.tpl",
    { secret_arn = data.aws_secretsmanager_secret.innersource-webhook-secret.arn }
  )

  tags = {
    OpenTofu    = "true"
    Environment = "dev"
  }
}

module "irsa-webhook" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"

  name = "${var.eks_data.name}-webhook-secret"

  oidc_providers = {
    innersource_app_oidc = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["argo-events:webhook"]
    }
  }

  policies = {
    policy = module.webhook_policy.arn
  }
}