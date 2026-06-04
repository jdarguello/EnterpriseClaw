source argocd/bootstrap.nu
source external-secrets/bootstrap.nu

def "main init gitops" [
    --gitops-agent:     string
    --cloud-provider:   string
] {
    if ($gitops_agent == "argocd") {
        main init gitops argocd --cloud-provider=$cloud_provider
    }
}

def "main init gitops argocd" [
    --cloud-provider:   string
] {
    #1. Install Argo CD using Helm
    argocd bootstrap --cloud-provider=$cloud_provider

    #2. Install External-Secrets Operator (ESO)!
    external-secrets bootstrap

}