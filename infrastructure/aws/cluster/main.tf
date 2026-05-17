module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${var.project}-cluster"
  cluster_version = var.cluster_version

  vpc_id                   = var.vpc_id
  subnet_ids               = var.private_subnet_ids
  control_plane_subnet_ids = var.private_subnet_ids

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    public = {
      name           = "${var.project}-nodes-public"
      instance_types = var.node_instance_types

      min_size     = 1
      max_size     = 3
      desired_size = 1

      subnet_ids = var.public_subnet_ids
    }

    private = {
      name           = "${var.project}-nodes-private"
      instance_types = var.node_instance_types

      min_size     = 1
      max_size     = 5
      desired_size = 2

      subnet_ids = var.private_subnet_ids
    }
  }

  tags = {
    Project = var.project
  }
}
