locals {
  dns_records = [
    for record_data in data.aws_route53_records.domain_records.resource_record_sets:
    record_data.name
  ]

  acm_options = {
    for dvo in module.acm.acm_certificate_domain_validation_options:
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }
}

data "aws_route53_zone" "selected" {
  name         = var.domain_name
  private_zone = false
}

data "aws_route53_records" "domain_records" {
  zone_id = data.aws_route53_zone.selected.zone_id
}

resource "aws_route53_record" "acm_config" {
  depends_on = [module.acm]
  for_each = local.acm_options
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = each.value.name
  type    = each.value.type

  ttl = 60
  records = [each.value.record]
}


module "acm" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 4.0"

  domain_name = var.domain_name
  zone_id     = data.aws_route53_zone.selected.zone_id

  validation_method = "DNS"

  subject_alternative_names = [
    for subdomain in var.subdomains:
    subdomain.url
  ]

  wait_for_validation = true

  tags = {
    Name = var.domain_name
  }
}