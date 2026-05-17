data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az_count        = length(data.aws_availability_zones.available.names)
  all_public_cidrs  = [for i in range(local.az_count) : cidrsubnet("10.0.0.0/16", 8, i + 1)]
  all_private_cidrs = [for i in range(local.az_count) : cidrsubnet("10.0.0.0/16", 8, i + 11)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project}-vpc"
  cidr = "10.0.0.0/16"

  azs             = data.aws_availability_zones.available.names
  public_subnets  = local.all_public_cidrs
  private_subnets = local.all_private_cidrs

  enable_nat_gateway     = true
  one_nat_gateway_per_az = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = {
    Project = var.project
  }
}