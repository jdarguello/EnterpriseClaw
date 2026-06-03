source external-secrets/install.nu
source pre-condition/main.nu

def "main kube-tools bootstrap" [
    --git-provider: string
    --cloud-provider:   string
    --gitops-setup:     string
    --gitops-helm-path= "gitops-config/helm"
] {
    #1. Install External-Secrets
    #external-secrets install

    #2. Kube-tools preconditioning - enable configuration via GitOps
    main kube-tools preconditioning --gitops-helm-path=$gitops_helm_path --git-provider=$git_provider --cloud-provider=$cloud_provider --gitops-setup=$gitops_setup
}