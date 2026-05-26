source ../git/main.nu

source alb-controller.nu

# Configures GitOps manifests with infrastructure data for correct DNS, ALB and Gateway Controllers setup
def "main preconditioning" [
    --git-provider: string
] {
    #1. Clone the config repository
    git clone --git-provider=$git_provider

    
}