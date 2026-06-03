output "secrets-arn" {
  value = module.secrets_pod_identity.iam_role_arn
}