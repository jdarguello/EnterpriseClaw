def --env "cluster aws setup tfvars" [
    --git-secret-name: string
    --webhook-secret-name: string
] {
    {
        "aws_region": $env.aws_region,
        "project": $"($env.COMPANY_NAME)-EnterpriseClaw",
        "cluster_name": "EnterpriseClaw-cluster",
        "dns_data" : {
            "domain_name": $env.domain_name,
            "subdomains": [
                {
                    "name": $"gitops",
                    "url": $"gitops.($env.domain_name)"
                },
                {
                    "name": $"workflows",
                    "url": $"workflows.($env.domain_name)"
                },
                {
                    "name": $"events",
                    "url": $"events.($env.domain_name)"
                }
            ]
        }
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