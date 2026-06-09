variable "secrets_registries" {
    description = "References of secrets registries in AWS Secrets Manager"
    type        = list(object({
        name = string
    }))
}

variable "cluster_name" {
    description = "EKS cluster name, used to name the IRSA role"
    type        = string
}

variable "oidc_provider_arn" {
    description = "OIDC provider ARN from the EKS cluster"
    type        = string
}

variable "project" {
  description = "Project name used as a prefix for resource tags"
  type        = string
}