def --env "cluster aws setup tfvars" [
    --git-secret-name: string
    --webhook-secret-name: string
] {
    {
        "vpc_id": $env.vpc_id,
        "aws_region": $env.aws_region,
        "eks_data": {
            name: $env.cluster_name
            kubernetes_version: $env.cluster_version
            eks_nodes: {
                backend: {
                    ami_type: $env.cluster_nodes_backend_ami
                    instance_type: [$env.cluster_nodes_backend_instance_type]
                    min_size: $env.cluster_nodes_backend_min_size
                    max_size: $env.cluster_nodes_backend_max_size
                    desired_size: $env.cluster_nodes_backend_desired_size
                }
                frontend: {
                    ami_type: $env.cluster_nodes_frontend_ami
                    instance_type: [$env.cluster_nodes_frontend_instance_type]
                    min_size: $env.cluster_nodes_frontend_min_size
                    max_size: $env.cluster_nodes_frontend_max_size
                    desired_size: $env.cluster_nodes_frontend_desired_size
                }
            }
        },
        "dns_data": {
            domain_name: $env.dns_data_domain_name
            subdomains: [
                {
                    name: $env.dns_data_gitops_name
                    url: $env.dns_data_gitops_url
                },
                {
                    name: $env.dns_data_workflows_name
                    url: $env.dns_data_workflows_url
                },
                {
                    name: $env.dns_data_events_name
                    url: $env.dns_data_events_url
                }
            ]
        },
        "alb_controller_chart_version": $env.alb_controller_chart_version,
        "external_dns_chart_version": $env.external_dns_chart_version,
        "innersource_app_name": $git_secret_name
        "innersource_webhook_secret_name": $webhook_secret_name
        "pipeline_storage_name": $"($env.COMPANY_NAME)-pipeline-storage"
    } | save env.auto.tfvars.json --force
}