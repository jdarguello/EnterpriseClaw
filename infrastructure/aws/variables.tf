variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name used as a prefix for resource tags"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.36"
}

variable "node_instance_types" {
  description = "EC2 instance types for managed node groups"
  type        = list(string)
  default     = ["t3.medium"]
}