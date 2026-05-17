module "network" {
  source = "./network"

  aws_region = var.aws_region
  project    = var.project
}

module "cluster" {
  source = "./cluster"

  project               = var.project
  cluster_name          = var.cluster_name
  cluster_version       = var.cluster_version
  node_instance_types   = var.node_instance_types
  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  private_subnet_ids    = module.network.private_subnet_ids
}
