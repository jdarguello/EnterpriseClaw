source ../../git/main.nu

source alb-controller.nu

# Configures GitOps manifests with infrastructure data for correct DNS, ALB and Gateway Controllers setup
def "main kube-tools preconditioning" [
    --git-provider: string
] {
    #0. Delete any historic repository
    rm -rf gitops-config/

    #1. Clone the config repository
    git-registry clone --git-provider=$git_provider

    #2. Patch manifest files
    alb-controller bootstrap

    #3. Push to registry


}