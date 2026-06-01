source ../utils/generals.nu
source ../infra/outputs.nu

def "external-secrets bootstrap" [
    --cloud-provider:   string        #Options: 'aws'
    --gitops-helm-path: string
] {
    #1. Load IaC Outputs!
    let infra_outputs = {
        clusterName: (infra output --output-name=eks_name --cloud-provider=$cloud_provider | str trim -c '"'),
        serviceAccountName: "git-sa",
        saAnnotation: (infra output --output-name=irsa-secrets-arn --cloud-provider=$cloud_provider | str trim -c '"')
    }

    #2. Patch External-Secrets Helm-vars file
    external-secrets patch helm-vars --infra-outputs=$infra_outputs --gitops-path=$gitops_helm_path

    #3. Patch ServiceAccount file
    
}

def "external-secrets patch helm-vars" [
    infra-outputs:  record
    gitops-path:    string
] {
    #1. Define helm-vars path
    let path = $"($gitops_path)/kube-essentials/external-dns/values.yaml"
    let abs_path = abs-path --path=$path

    #2. Generar Helm vars
    {
        "external-dns": {
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
        }
    } | to yaml | save $abs_path --force
}