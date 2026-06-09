
def --env "argo-events bootstrap" [
    --namespace = "argo-events"
    --github-secret-name: string
    --webhook-secret-name = "InnerSource-Webhook-Secret"
    --irsa-inner-output-name = "innersource-secrets-arn"
    --environment: string
    --gitops-path-base: string      #Path base para la relación GitOps
    --gitops-helm-path: string      #Path de instalación de helm-charts
] {
    #0. Obtener información de subnets disponibles
    let opentofu_outputs = {
        ingress_annotation_subnets: (opentofu output --environment=$environment --output-name=public-subnets | from json | str join ",")
    }

    #1. Instalar Argo Events
    argo events install --namespace=$namespace --environment=$environment --gitops-helm-path=$gitops_helm_path

    #2. Registrar secretos de GitHub App (SA)
    argo events secrets-sa manifest --irsa-output-name=$irsa_inner_output_name --environment=$environment --gitops-path-base=$gitops_path_base --namespace=$namespace

    #3. Registrar secreto del Webhook (SA)
    argo events secrets-sa manifest --sa-file="sa-webhook-patch.yaml" --role-name="webhook" --irsa-output-name="irsa-webhook-arn" --environment=$environment --gitops-path-base=$gitops_path_base --namespace=$namespace
    #external-secrets github creds --secret-store-name="webhook-secret" --environment=$environment --external-secret-name="webhook-secret" --irsa-role-name="webhook" --irsa-output-name="irsa-webhook-arn" --create-ns=false --namespace=$namespace --secret-name=$webhook_secret_name
}