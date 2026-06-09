source ../../../../infra/outputs.nu

source helm.nu
source sa.nu

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

    #3. Patch ServiceAccount S3
    #argo workflows s3-sa --environment=$environment --namespace=$namespace --gitops-path-base=$gitops_path_base

    #4. Patch SA Secrets Manager
    #argo workflows secrets-sa manifest --namespace=$namespace --irsa-output-name=$irsa_output_name --environment=$environment --gitops-path-base=$gitops_path_base
}