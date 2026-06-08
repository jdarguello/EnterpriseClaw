source ../../infra/outputs.nu
source patches.nu

#Service mesh (Istio) configuration for every component of the framework. Configures Virtual Service, Istio Gateway and Ingress Gateway
def --env "main service-mesh preconditioning" [
    --cloud-provider: string
] {
    #0. Obtain infra-outputs
    let infra_outputs = {
        ingress_annotation_subnets: (infra output --cloud-provider=$cloud_provider --output-name=public_subnet_ids | from json | str join ",")
    }

    #1. Service mesh patches for Argo CD
    istio components patch --infra-outputs=$infra_outputs --kubetool="argocd" --hostname=$"gitops.($env.domain_name)"

    #2. Service mesh patches for Argo Workflows
    istio components patch --infra-outputs=$infra_outputs --kubetool="argo-workflows" --hostname=$"workflows.($env.domain_name)"

    #3. Service mesh patches for Argo Events
    istio components patch --infra-outputs=$infra_outputs --kubetool="argo-events" --hostname=$"events.($env.domain_name)"
}