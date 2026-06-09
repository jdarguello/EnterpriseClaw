# network
output "vpc_id" {
  value = module.network.vpc_id
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

# cluster
output "cluster_name" {
  value = module.cluster.cluster_name
}

output "cluster_endpoint" {
  value = module.cluster.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value     = module.cluster.cluster_certificate_authority_data
  sensitive = true
}

output "oidc_provider_arn" {
  value = module.cluster.oidc_provider_arn
}

# dns
output "dns_records_names" {
  value = module.dns.dns_records_names
}

output "domain_records" {
  value = module.dns.domain_records
}

output "domain_zone" {
  value = module.dns.domain_zone
}

output "acm_options" {
  value = module.dns.acm_options
}

output "external_dns_arn" {
  value = module.dns.external_dns_arn
}

output "alb-arn" {
  value = module.dns.alb-arn
}

# secrets-manager
output "secrets-pod-identity-arn" {
  value = module.secrets-manager.secrets-pod-identity-arn
}

output "secrets-arn" {
  value = module.secrets-manager.secrets-arn
}

# image-registries
output "actions_registries_urls" {
  value = module.image-registries.actions_registries_urls
}

output "irsa-ecr-actions-arn" {
  value = module.image-registries.irsa-ecr-actions-arn
}

# pipe-storage
output "irsa-pipeline-storage-arn" {
  value = module.pipe-storage.irsa-pipeline-storage-arn
}

output "pipeline-storage-domain-name" {
  value = module.pipe-storage.pipeline-storage-domain-name
}