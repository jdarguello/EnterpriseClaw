source argocd/bootstrap.nu

def "main init gitops" [
    --gitops-agent:string
] {
    if ($gitops_agent == "argocd") {
        argocd bootstrap
    }
}