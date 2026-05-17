variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
}

variable "project" {
  description = "Project name used as a prefix for resource tags"
  type        = string
}