variable "project" {
  description = "Project name used as a prefix for resource names and tags"
  type        = string
}


variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the EKS cluster will be deployed"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs — nodes can be placed here"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs — nodes can be placed here"
  type        = list(string)
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
