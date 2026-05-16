#Creates the EnterpriseClaw main k8s cluster
def --env "main cluster setup" [
    --cloud-provider:string
    --cluster-name:string
    --innersource-secret-name: string
    --webhook-secret-name: string
] {
    #1. Change directory to infra path
    let current_directory = pwd
    cd $"../infrastructure/($cloud_provider)"

    #2. Inicializar OpenTofu
    tofu init

    #3. Definir variables de infraestructura - tfvars
    cluster setup tfvars --innersource-secret-name=$innersource_secret_name --webhook-secret-name=$webhook_secret_name

    #4. Ejecutar OpenTofu
    tofu apply -auto-approve -exclude=aws_route53_record.acm_config

    #5. Regresar al path original
    cd $current_directory
}

def "cluster teardown" [
    --environment:string
] {
    #1. Ir al path de infraestructura
    let current_directory = pwd
    cd $"../infra/($environment)"

    #2. Inicializar OpenTofu
    tofu init

    #3. Eliminar infraestructura
    tofu destroy -auto-approve -exclude=aws_route53_record.acm_config

    #4. Regresar al path original
    cd $current_directory
}

def --env "cluster setup tfvars" [
    --innersource-secret-name: string
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
        "innersource_app_name": $innersource_secret_name
        "innersource_webhook_secret_name": $webhook_secret_name
        "pipeline_storage_name": $"($env.COMPANY_NAME)-pipeline-storage"
    } | save env.auto.tfvars.json --force
}