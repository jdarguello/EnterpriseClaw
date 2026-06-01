source external-secrets/install.nu
source pre-condition/main.nu

def "main kube-tools bootstrap" [
    --git-provider: string
] {
    #1. Install External-Secrets
    external-secrets install

    #2. Kube-tools preconditioning - enable configuration via GitOps
    main kube-tools preconditioning --git-provider=$git_provider
}