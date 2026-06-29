locals {
  actions_files = fileset("../../", "actions/*/*.md")

  actions_names = [
    for path in local.actions_files :
    split("/", dirname(path))[1]
  ]
}

module "irsa-ecr-actions" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"

  name = "${var.cluster_name}-ecr-actions"

  oidc_providers = {
    cluster_oidc = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["argo:ecr-actions"]
    }
  }
}

module "actions_registries" {
  source = "terraform-aws-modules/ecr/aws"

  for_each = toset(local.actions_names)

  repository_name = "${lower(var.project)}/${lower(each.value)}"

  repository_read_write_access_arns = [module.irsa-ecr-actions.arn]
  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Save last 30 images",
        selection = {
          tagStatus     = "tagged",
          tagPrefixList = ["v"],
          countType     = "imageCountMoreThan",
          countNumber   = 30
        },
        action = {
          type = "expire"
        }
      }
    ]
  })

  tags = {
    OpenTofu = "true"
    Project  = var.project
  }
}