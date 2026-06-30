source ../git/main.nu

source pre-condition/main.nu
source service-mesh/main.nu

source ../gitops/app-of-apps.nu
source ../gitops/broker-exposure.nu
source ../gitops/kagent-exposure.nu
source ../gitops/broker-keycloak-config.nu
source ../gitops/bedrock-irsa.nu

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
    #   The broker/Keycloak Ingress rides the shared platform ALB, so it needs the same public
    #   subnets the service-mesh ingress patches use.
    let broker_subnets = (infra output --cloud-provider=$cloud_provider --output-name=public_subnet_ids | from json | str join ",")
    let broker_domain = ($env.domain_name | str trim -c '"')
    app-of-apps register-agents
    app-of-apps register-session-broker
    # Inject the tenant's Bedrock IRSA role ARN (live infra output `bedrock_irsa_arn`) onto the
    # agentgateway LLM-gateway proxy SA, via a CLI-generated AgentgatewayParameters object delivered
    # through the private repo (the public agentic tree stays ARN-free). See cli/gitops/bedrock-irsa.nu.
    bedrock-irsa render --cloud-provider=$cloud_provider
    broker-exposure render --domain=$broker_domain --subnets=$broker_subnets
    # Expose the kagent dashboard UI (ai-platform.<domain>) on the same shared platform ALB.
    kagent-exposure render --domain=$broker_domain --subnets=$broker_subnets
    # Tenant Keycloak/broker external hostnames (the CLI owns the value; the broker repo consumes the
    # ConfigMaps via its $(env:...) seam — see cli/gitops/broker-keycloak-config.nu).
    broker-keycloak-config render --domain=$broker_domain

    #5. Push to registry
    if ($gitops_setup == "push") {
        git-registry push --git-provider=$git_provider --commit-message="gitops: identifier patches"
    }
}