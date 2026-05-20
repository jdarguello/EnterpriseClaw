output "dns_records_names" {
  value = local.dns_records
}

output "domain_records" {
  value = data.aws_route53_records.domain_records.resource_record_sets
}

output "domain_zone" {
  value = data.aws_route53_zone.selected.zone_id
}

output "acm_options" {
  value = module.acm.acm_certificate_domain_validation_options
}

output "external_dns_arn" {
  value = module.irsa-external-dns.arn
}