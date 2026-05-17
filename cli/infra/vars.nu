def --env "cluster aws setup tfvars" [
    --git-secret-name: string
    --webhook-secret-name: string
] {
    {
        "aws_region": $env.aws_region,
        "project": $"($env.COMPANY_NAME)-EnterpriseClaw"
    } | save env.auto.tfvars.json --force
}