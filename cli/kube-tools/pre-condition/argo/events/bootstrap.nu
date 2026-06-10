source ../../../../infra/outputs.nu
source ../../../../utils/generals.nu
source ../../external-secrets/sa.nu

source helm.nu

def "argo-events bootstrap" [
    --cloud-provider: string
] {
    #1. Adjust Helm-vars
    argo-events helm --namespace="argo-events" --cloud-provider=$cloud_provider

    #2. Patch ServiceAccount webhook
    argo-events bootstrap patch webhook --cloud-provider=$cloud_provider

    #3. Patch SA Secrets Manager
    argo-events bootstrap patch secrets-manager --cloud-provider=$cloud_provider
}

def "argo-events bootstrap patch webhook" [
    --cloud-provider: string
] {
    #1. Obtain pipe-storage irsa arn
    let irsa_arn = (infra output --cloud-provider=$cloud_provider --output-name="irsa-pipeline-storage-arn")

    #2. Set saving path
    let save_path = abs-path --path="gitops-config/config/argo-events/sa-webhook.yaml" --replace-argument=""

    #3. Patch ServiceAccount manifest
    external-secrets sa irsa --namespace="argo" --role-arn=$irsa_arn --role-name="pipe-storage" --save-path=$save_path
}

def "argo-events bootstrap patch secrets-manager" [
    --cloud-provider: string
] {
    #1. Obtain pipe-storage irsa arn
    let irsa_arn = (infra output --cloud-provider=$cloud_provider --output-name="secrets-arn")

    #2. Set saving path
    let save_path = abs-path --path="gitops-config/config/argo-events/sa-secrets.yaml" --replace-argument=""

    #3. Patch ServiceAccount manifest
    external-secrets sa irsa --namespace="argo" --role-arn=$irsa_arn --role-name="secrets-manager" --save-path=$save_path
}