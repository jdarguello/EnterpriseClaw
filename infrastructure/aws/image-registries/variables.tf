variable "project" {
  description = "Project name used as a prefix for resource names and tags"
  type        = string
}


variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "oidc_provider_arn" {
    description = "OIDC provider ARN from the EKS cluster"
    type        = string
}