locals {
  common_tags = {
    Project     = var.project
    ManagedBy   = "terraform"
    Environment = "bootstrap"
  }
}

module "tf_state_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = var.bucket_name

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  lifecycle_rule = [
    {
      id      = "expire-old-noncurrent-versions"
      enabled = true

      noncurrent_version_expiration = {
        days = 90
      }
    }
  ]

  # Prevent accidental destruction of state history
  force_destroy = false

  tags = local.common_tags
}

module "tf_state_lock" {
  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "~> 4.0"

  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attributes = [
    {
      name = "LockID"
      type = "S"
    }
  ]

  tags = local.common_tags
}
