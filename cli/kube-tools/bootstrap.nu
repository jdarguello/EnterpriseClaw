source ../git/main.nu

source pre-condition/main.nu
source service-mesh/main.nu

source ../gitops/app-of-apps.nu
source ../gitops/broker-exposure.nu

def "main kube-tools bootstrap" [
    --git-provider: string
    --cloud-provider:   string
    --gitops-setup:     string
    --gitops-helm-path= "gitops-config/helm"
] {
    #0. Delete any historic repository
    rm -rf gitops-config/

    #1. Clone the config repository
    git-registry clone --git-provider=$git_provider

    #2. Kube-tools preconditioning - enable configuration via GitOps
    main kube-tools preconditioning --gitops-helm-path=$gitops_helm_path --git-provider=$git_provider --cloud-provider=$cloud_provider --gitops-setup=$gitops_setup

    #3. Service Mesh preconditioning
    main service-mesh preconditioning --cloud-provider=$cloud_provider

    #4. Register the agentic platform (kagent trio + agentic CRs) and the Session-Broker into the
    #   tenant app-of-apps, plus their Istio internet exposure — all before the push so Argo CD
    #   reconciles them on first sync. See cli/gitops/app-of-apps.nu + broker-exposure.nu.
    app-of-apps register-agents
    app-of-apps register-session-broker
    broker-exposure render --domain=($env.domain_name | str trim -c '"')

    #5. Push to registry
    if ($gitops_setup == "push") {
        git-registry push --git-provider=$git_provider --commit-message="gitops: identifier patches"
    }
}