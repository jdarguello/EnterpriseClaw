source ../../git/main.nu

source alb-controller.nu
source external-dns.nu
source istio.nu

# Configures GitOps manifests with infrastructure data for correct DNS, ALB and Gateway Controllers setup
def "main kube-tools preconditioning" [
    --git-provider:     string
    --cloud-provider:   string
    --gitops-setup:     string
    --gitops-helm-path= "gitops-config/helm"
] {
    #0. Delete any historic repository
    rm -rf gitops-config/

    #1. Clone the config repository
    git-registry clone --git-provider=$git_provider

    #2. Patch manifest files
    #external-secrets bootstrap --cloud-provider=$cloud_provider --gitops-helm-path=$gitops_helm_path
    alb-controller bootstrap --cloud-provider=$cloud_provider --gitops-helm-path=$gitops_helm_path
    external-dns bootstrap --cloud-provider=$cloud_provider --gitops-helm-path=$gitops_helm_path
    istio bootstrap --gitops-helm-path=$gitops_helm_path

    #3. Push to registry
    if ($gitops_setup == "push") {
        git-registry push --git-provider=$git_provider --commit-message="gitops: identifier patches"
    }
}