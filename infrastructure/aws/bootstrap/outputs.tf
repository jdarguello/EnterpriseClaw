output "state_bucket_name" {
  description = "S3 bucket name to use in the backend configuration"
  value       = module.tf_state_bucket.s3_bucket_id
}

output "state_bucket_arn" {
  description = "ARN of the S3 state bucket"
  value       = module.tf_state_bucket.s3_bucket_arn
}

output "dynamodb_table_name" {
  description = "DynamoDB table name to use in the backend configuration"
  value       = module.tf_state_lock.dynamodb_table_id
}
