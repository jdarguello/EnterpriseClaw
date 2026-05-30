source ../../infra/outputs.nu

def --env "argocd bootstrap" [
    --namespace = "argocd"
] {
    #0. Get subnets info!
    let infra_outputs = {
        ingress_annotation_subnets: (opentofu output --environment=$environment --output-name=public-subnets | from json | str join ",")
    }

    #1. Instalar ArgoCD
    argo cd install --namespace=$namespace --infra-outputs=$infra_outputs
}

def --env "argocd install" [
    --admin-enabled = true
    --namespace: string
    --infra-outputs: record
] {
    #0. Create namespace
    kubectl create ns $namespace

    #2. Define helm-vars
    argo cd helm vars --admin-enabled=$admin_enabled --namespace=$namespace --infra-outputs=$infra_outputs

    #3. Install with helm
    helm repo add argo https://argoproj.github.io/argo-helm
    helm install argo-cd argo/argo-cd --version $env.argocd_version -f tmp/argocd-vars.yaml

    #4. Wait until it rollouts!
    kubectl -n argocd rollout status --watch --timeout=600s deployment/argo-cd-argocd-server
    kubectl -n argocd rollout status --watch --timeout=600s deployment.apps/argo-cd-argocd-repo-server
}

