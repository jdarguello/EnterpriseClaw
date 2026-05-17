source vars.nu

#Comes before cluster setup. Its goal is to create terraform's persistant state in the cloud before moving further.
def --env "main cluster bootstrap" [
    --cloud-provider: string
] {
    #1. Change directory to infra path
    let current_directory = pwd
    cd $"../infrastructure/($cloud_provider)/bootstrap"

    #2. Initialize OpenTofu
    tofu init

    #3. Define tfvars
    cluster aws bootstrap tfvars

    #4. Execute OpenTofu
    tofu apply -auto-approve

    #5. Return to original path
    cd $current_directory

}

def "main cluster bootstrap destroy" [
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