source argocd/bootstrap.nu

def "main init gitops" [
    --gitops-agent:     string
    --cloud-provider:   string
] {
    if ($gitops_agent == "argocd") {
        argocd bootstrap --cloud-provider=$cloud_provider
    }
}