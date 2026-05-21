source vars.nu

#Creates the EnterpriseClaw main k8s cluster
def --env "main cluster setup" [
    --cloud-provider:string
    --cluster-name:string
    --git-secret-name: string
    --webhook-secret-name: string
] {
    #1. Change directory to infra path
    let current_directory = pwd
    cd $"../infrastructure/($cloud_provider)"

    #2. Initialize OpenTofu
    tofu init

    #3. Define infrastructure variables! - tfvars
    if ($cloud_provider == "aws") {
        cluster aws setup tfvars --cluster-name=$cluster_name --git-secret-name=$git_secret_name --webhook-secret-name=$webhook_secret_name
    }

    #4. Execute OpenTofu
    tofu apply -auto-approve -exclude=aws_route53_record.acm_config

    #5. Return to original path
    cd $current_directory
}

def "main cluster teardown" [
    --cloud-provider:string
] {
    #1. Ir al path de infraestructura
    let current_directory = pwd
    cd $"../infrastructure/($cloud_provider)"

    #2. Inicializar OpenTofu
    tofu init

    #3. Eliminar infraestructura
    if ($cloud_provider == "aws") {
        tofu destroy -auto-approve -exclude=aws_route53_record.acm_config
    }
    
    #4. Regresar al path original
    cd $current_directory
}