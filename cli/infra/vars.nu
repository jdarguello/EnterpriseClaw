def --env "cluster aws setup tfvars" [
    --git-secret-name: string
    --webhook-secret-name: string
] {
    {
        "aws_region": $env.aws_region,
        "project": $"($env.COMPANY_NAME)-EnterpriseClaw",
        "cluster_name": "EnterpriseClaw"
    } | save env.auto.tfvars.json --force
}

def --env "cluster aws bootstrap tfvars" [] {
    {
        "aws_region": $env.aws_region,
        "project": $"($env.COMPANY_NAME)-EnterpriseClaw",
        "bucket_name": $"($env.COMPANY_NAME)-EnterpriseClaw-state-storage",
        "dynamodb_table_name": $"($env.COMPANY_NAME)-EnterpriseClaw-state-lock"
    } | save env.auto.tfvars.json --force
}