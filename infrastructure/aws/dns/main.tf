locals {
  dns_records = [
    for record_data in data.aws_route53_records.domain_records.resource_record_sets:
    record_data.name
  ]
}

data "aws_route53_zone" "selected" {
  name         = var.domain_name
  private_zone = false
}

data "aws_route53_records" "domain_records" {
  zone_id = data.aws_route53_zone.selected.zone_id
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

module "external_dns_policy" {
  source = "terraform-aws-modules/iam/aws//modules/iam-policy"

  name        = "external-dns-policy"
  path        = "/"
  description = "IAM Permissions for External-DNS to configure DNS Records"

  policy = file("${path.module}/policies/external_dns.json")

  tags = {
    OpenTofu    = "true"
    Environment = "dev"
  }
}

module "irsa-external-dns" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"

  name = "${var.cluster_name}-external-dns"

  oidc_providers = {
    dns_oidc = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["kube-system:external-dns", "external-dns:external-dns"]
    }
  }

  policies = {
    policy = module.external_dns_policy.arn
  }
}