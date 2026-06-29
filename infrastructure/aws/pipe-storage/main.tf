module "pipeline-storage" {
  source = "terraform-aws-modules/s3-bucket/aws"

  bucket = var.pipeline_storage_name
  acl    = "private"

  control_object_ownership = true
  object_ownership         = "ObjectWriter"

  versioning = {
    enabled = false
  }

  force_destroy = true

  tags = {
    Project : var.project
  }
}

module "pipeline_storage_policy" {
  source = "terraform-aws-modules/iam/aws//modules/iam-policy"

  name        = "pipeline-storage-policy"
  path        = "/"
  description = "IAM permissions to upload and download artifacts"

  policy = templatefile(
    "${path.module}/policies/pipeline_artifacts_storage.tpl",
    { bucket_arn = module.pipeline-storage.s3_bucket_arn }
  )

  tags = {
    Project : var.project
  }
}

module "irsa-pipeline-storage" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"

  name = "${var.project}-pipe-storage"

  oidc_providers = {
    workflow_oidc = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["argo:pipe-storage"]
    }
  }

  policies = {
    s3_policy = module.pipeline_storage_policy.arn,
  }
}