output "secrets-pod-identity-arn" {
  value = module.secrets_pod_identity.iam_role_arn
}

output "secrets-arn" {
  value = module.irsa_secrets_manager.arn
}