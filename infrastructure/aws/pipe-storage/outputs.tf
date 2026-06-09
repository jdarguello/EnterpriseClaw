output "irsa-pipeline-storage-arn" {
  value = module.irsa-pipeline-storage.arn
}

output "pipeline-storage-domain-name" {
  value = module.pipeline-storage.s3_bucket_bucket_domain_name
}

output "pipeline-storage-name" {
  value = module.pipeline-storage.s3_directory_bucket_name
}