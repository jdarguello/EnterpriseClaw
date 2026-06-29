variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name used as a prefix for resource tags"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.32"
}

variable "node_instance_types" {
  description = "EC2 instance types for managed node groups"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "dns_data" {
  description = "Data to DNS usage"
  type = object({
    domain_name = string
    subdomains = list(object({
      name = string
      url  = string
    }))
  })
}

variable "secrets_registries" {
  description = "References of secrets registries in AWS Secrets Manager"
  type = list(object({
    name = string
  }))
}