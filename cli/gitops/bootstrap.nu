source argocd/bootstrap.nu
source external-secrets/bootstrap.nu

source ../utils/generals.nu

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

    #2. Install and configure External-Secrets Operator (ESO)!
    external-secrets bootstrap

    #3. Now, link user's private repo with general config
    gitops user repo --gitops-agent="argocd"
}

def "gitops user repo" [
    --gitops-agent:     string
] {
    let main_path = abs-path --path="/gitops-config/main.yaml" --replace-argument=""
    if ($gitops_agent == "argocd") {
        kubectl create -f $main_path
    }
}
