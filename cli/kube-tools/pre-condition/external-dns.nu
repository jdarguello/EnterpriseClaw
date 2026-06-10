source ../../utils/generals.nu
source ../../infra/outputs.nu

def "external-dns bootstrap" [
    --cloud-provider:   string        #Options: 'aws'
    --gitops-helm-path: string
] {
    #1. Load IaC Outputs!
    let infra_outputs = {
        clusterName: (infra output --output-name=cluster_name --cloud-provider=$cloud_provider | str trim -c '"'),
        serviceAccountName: "external-dns",
        saAnnotation: (infra output --output-name=external_dns_arn --cloud-provider=$cloud_provider | str trim -c '"')
    }

    #2. Patch External-DNS Config file
    external-dns patch helm-vars --infra-outputs=$infra_outputs --gitops-path=$gitops_helm_path
}

def "external-dns patch helm-vars" [
    --infra-outputs:  record
    --gitops-path:    string
] {
    #1. Define helm-vars path
    let path = $"($gitops_path)/kube-essentials/external-dns/values.yaml"
    let abs_path = abs-path --path=$path --replace-argument=""

    #2. Generar Helm vars
    {
        policy: "sync"
        txtOwnerId: $infra_outputs.clusterName
        provider: {
            name: "aws"
        }
        serviceAccount: {
            create: true
            name: $infra_outputs.serviceAccountName
            annotations: {
                "eks.amazonaws.com/role-arn": $infra_outputs.saAnnotation
            }
        }
    } | to yaml | save $abs_path --force
}