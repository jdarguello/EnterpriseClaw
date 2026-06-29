output "actions_registries_urls" {
  value = {
    for ecr_registry in module.actions_registries :
    ecr_registry.repository_name => ecr_registry.repository_url
  }
}

output "irsa-ecr-actions-arn" {
  value = module.irsa-ecr-actions.arn
}