# aws/ecr.nu — minimal AWS ECR helpers for the container build/push path.
#
# Recreated 2026-07-01 (the old `cli/aws/` dir never existed, which broke `source ../aws/ecr.nu`).
# Provides the small set of AWS lookups the podman build/login/push flow needs. Reads region from
# `$env.region` (Devbox loads cli/.env). Account id is derived from `aws sts get-caller-identity`
# (NOT the old `$env.AWS_ROLE` split hack, which relied on an env var that isn't set).
#
# Requires the `aws` CLI (present in Devbox). This module is ONLY sourced by the containers module,
# which itself is a build-time tool — it is not on the slim in-cluster image's load path.

# The AWS account id of the current caller.
def --env "ecr account-id" [] {
    aws sts get-caller-identity --query Account --output text | str trim
}

# The ECR registry host: <account-id>.dkr.ecr.<region>.amazonaws.com
def --env "ecr registry-host" [
    --region: string = ""
] {
    let r = (if ($region | is-not-empty) { $region } else { $env.region })
    let account = (ecr account-id)
    $"($account).dkr.ecr.($r).amazonaws.com"
}

# An ECR login password (equivalent to `aws ecr get-login-password`).
def --env "ecr password" [
    --region: string = ""
] {
    let r = (if ($region | is-not-empty) { $region } else { $env.region })
    aws ecr get-login-password --region $r | str trim
}

# The full repository URI for a given repo name (e.g. "Acme-EnterpriseClaw/checkout").
def --env "ecr repo-uri" [
    --repo-name: string
    --region: string = ""
] {
    let host = (ecr registry-host --region=$region)
    $"($host)/($repo_name)"
}
