module "network" {
  source = "./network"

  aws_region  = var.aws_region
  project     = var.project
}
