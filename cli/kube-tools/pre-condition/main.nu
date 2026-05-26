source ../../git/main.nu

source alb-controller.nu

# Configures GitOps manifests with infrastructure data for correct DNS, ALB and Gateway Controllers setup
def "main preconditioning" [
    --git-provider: string
] {
    #1. Clone the config repository
    git-registry clone --git-provider=$git_provider

    #2. Patch manifest files
    

    #3. Push to registry


}