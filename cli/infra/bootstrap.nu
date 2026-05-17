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

}

def "cluster bootstrap aws" [] {
    
}