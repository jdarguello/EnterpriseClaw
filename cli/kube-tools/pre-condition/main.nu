source argo/workflows/bootstrap.nu
source argo/events/bootstrap.nu

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
    #1. Patch manifest files
    alb-controller bootstrap --cloud-provider=$cloud_provider --gitops-helm-path=$gitops_helm_path
    external-dns bootstrap --cloud-provider=$cloud_provider --gitops-helm-path=$gitops_helm_path
    istio bootstrap --cloud-provider=$cloud_provider --gitops-helm-path=$gitops_helm_path

    #2. Patch Argo files
    argo-workflows bootstrap --cloud-provider=$cloud_provider
    argo-events bootstrap --cloud-provider=$cloud_provider
}