locals {
  secrets_map = { for s in var.secrets_registries : s.name => s }
  # Read references (existing SM secrets) + the keycloak-internal secret this
  # module auto-provisions, so ESO's read policy is scoped to all of them.
  secret_arns = concat(
    [for s in data.aws_secretsmanager_secret.secrets : s.arn],
    [aws_secretsmanager_secret.keycloak_internal.arn]
  )
}

data "aws_secretsmanager_secret" "secrets" {
  for_each = local.secrets_map
  name     = each.key
}

# ---------------------------------------------------------------------------
# Platform-internal secrets for the Keycloak / Session-Broker stack.
# Auto-provisioned here so the demo platform is self-seeding; the JSON keys
# below are consumed verbatim by downstream ExternalSecrets.
# special = false: alphanumeric only — these flow into Postgres connection
# strings, OAuth client secrets, and $(env:...) substitution in
# keycloak-config-cli, where special chars risk breaking parsing.
# ---------------------------------------------------------------------------
resource "random_password" "keycloak_admin_password" {
  length  = 32
  special = false
}

resource "random_password" "keycloak_postgres_password" {
  length  = 32
  special = false
}

resource "random_password" "keycloak_password" {
  length  = 32
  special = false
}

resource "random_password" "keycloak_session_broker_client_secret" {
  length  = 32
  special = false
}

resource "random_password" "keycloak_kagent_controller_client_secret" {
  length  = 32
  special = false
}

resource "random_password" "keycloak_alice_password" {
  length  = 32
  special = false
}

# Redis (Session-Broker cache) auth password — the broker repo's redis chart
# sets auth.existingSecret=redis-secret / key redis-password.
resource "random_password" "keycloak_redis_password" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "keycloak_internal" {
  name = "keycloak-internal"
  # Ephemeral demo platform: destroyed + recreated each init. A 30-day
  # pending-deletion window would block re-creation on the next init.
  recovery_window_in_days = 0

  tags = {
    OpenTofu    = "true"
    Environment = "dev"
  }
}

resource "aws_secretsmanager_secret_version" "keycloak_internal" {
  secret_id = aws_secretsmanager_secret.keycloak_internal.id
  secret_string = jsonencode({
    "admin-password"                  = random_password.keycloak_admin_password.result
    "postgres-password"               = random_password.keycloak_postgres_password.result
    "password"                        = random_password.keycloak_password.result
    "session-broker-client-secret"    = random_password.keycloak_session_broker_client_secret.result
    "kagent-controller-client-secret" = random_password.keycloak_kagent_controller_client_secret.result
    "alice-password"                  = random_password.keycloak_alice_password.result
    "redis-password"                  = random_password.keycloak_redis_password.result
  })
}

module "secrets_policy" {
  source = "terraform-aws-modules/iam/aws//modules/iam-policy"

  name        = "secrets-policy"
  path        = "/"
  description = "IAM permissions to read secrets from Secrets Manager"

  policy = templatefile(
    "${path.module}/policies/secrets_policy.tpl",
    { secret_arns = local.secret_arns }
  )

  tags = {
    OpenTofu    = "true"
    Environment = "dev"
  }
}

module "irsa_secrets_manager" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"

  name = "${var.project}-secrets"

  oidc_providers = {
    workflow_oidc = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["argo:secrets-manager"]
    }
  }

  policies = {
    secrets_policy = module.secrets_policy.arn,
  }
}

module "secrets_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0" # ← verify current major on the registry before applying

  name = "${var.cluster_name}-secrets"

  # same policy ARN as before, attached via additional_policy_arns
  additional_policy_arns = {
    secrets = module.secrets_policy.arn
  }

  # set cluster_name once instead of repeating it per association
  association_defaults = {
    cluster_name = "${var.cluster_name}-cluster"
  }

  associations = {
    argo-events-webhook = {
      namespace       = "argo-events"
      service_account = "webhook"
    }
    argocd-git-sa = {
      namespace       = "argocd"
      service_account = "git-sa"
    }
    external-secrets-git-sa = {
      namespace       = "external-secrets"
      service_account = "git-sa"
    }
    external-secrets-controller = {
      namespace       = "external-secrets"
      service_account = "external-secrets"
    }
  }

  tags = {
    OpenTofu    = "true"
    Environment = "dev"
  }
}