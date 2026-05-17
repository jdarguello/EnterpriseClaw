variable "pipeline_storage_name" {
  description = "Name of the S3 Bucket where all pipeline artifacts will be stored"
  type        = string
}

variable "project" {
  description = "Project name used as a prefix for resource tags"
  type        = string
}
