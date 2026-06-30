def --env "cluster aws setup tfvars" [
    --git-secret-name: string
    --webhook-secret-name: string
    --cluster-name: string
] {
    {
        "aws_region": $env.region,
        "project": $"($env.COMPANY_NAME)-EnterpriseClaw",
        "cluster_name": $cluster_name,
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
                },
                {
                    "name": $"auth",
                    "url": $"auth.($env.domain_name)"
                },
                {
                    "name": $"ai-platform",
                    "url": $"ai-platform.($env.domain_name)"
                },
                {
                    "name": $"broker",
                    "url": $"broker.($env.domain_name)"
                }
            ]
        },
        "secrets_registries": [
            {"name": $env.github_app_registry},
            {"name": $env.github_webhook_registry},
            {"name": "google-idp"},
            {"name": "github-readonly-token"},
            {"name": "slack-creds"}
        ]
    } | save env.auto.tfvars.json --force
}

def --env "cluster aws bootstrap tfvars" [] {
    {
        "aws_region": $env.region,
        "project": $"($env.COMPANY_NAME)-EnterpriseClaw",
        "bucket_name": $"($env.COMPANY_NAME)-EnterpriseClaw-state-storage",
        "dynamodb_table_name": $"($env.COMPANY_NAME)-EnterpriseClaw-state-lock"
    } | save env.auto.tfvars.json --force
}