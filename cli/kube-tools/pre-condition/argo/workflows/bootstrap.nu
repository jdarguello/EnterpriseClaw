source ../../../../infra/outputs.nu
source ../../../../utils/generals.nu
source ../../external-secrets/sa.nu

source helm.nu

def "argo-workflows bootstrap" [
    --irsa-output-name = "innersource-secrets-arn"
    --cloud-provider:       string
    --github-secret-name: string
    --gitops-path-base: string
    --gitops-helm-path: string
] {
    #1. Public subnets info
    let infra_outputs = {
        ingress_annotation_subnets: (infra output --cloud-provider=$cloud_provider --output-name=public_subnet_ids | from json | str join ",")
    }

    #2. Adjust Helm-vars
    argo workflows helm --infra-outputs=$opentofu_outputs --cloud-provider=$cloud_provider

    #3. Patch ServiceAccount pipe-storage
    argo-workflows bootstrap patch pipe-storage --cloud-provider=$cloud_provider

    #4. Patch SA Secrets Manager
    argo-workflows bootstrap patch secrets-manager --cloud-provider=$cloud_provider
}

def "argo-workflows bootstrap patch pipe-storage" [
    --cloud-provider: string
] {
    #1. Obtain pipe-storage irsa arn
    let irsa_arn = (opentofu output --cloud-provider=$cloud_provider --output-name="irsa-pipeline-storage-arn")

    #2. Set saving path
    let save_path = abs-path --path="gitops-config/config/argo-workflows/sa-pipe-patch.yaml" --replace-argument=""

    #3. Patch ServiceAccount manifest
    external-secrets sa irsa --namespace="argo" --role-arn=$irsa_arn --role-name="pipe-storage" --save-path=$save_path
}

def "argo-workflows bootstrap patch secrets-manager" [
    --cloud-provider: string
] {
    #1. Obtain pipe-storage irsa arn
    let irsa_arn = (opentofu output --cloud-provider=$cloud_provider --output-name="secrets-arn")

    #2. Set saving path
    let save_path = abs-path --path="gitops-config/config/argo-workflows/sa-pipe-patch.yaml" --replace-argument=""

    #3. Patch ServiceAccount manifest
    external-secrets sa irsa --namespace="argo" --role-arn=$irsa_arn --role-name="pipe-storage" --save-path=$save_path
}