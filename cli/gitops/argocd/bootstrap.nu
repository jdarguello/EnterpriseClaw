source ../../infra/outputs.nu

source helm-vars.nu 

def --env "argocd bootstrap" [
    --namespace = "argocd"
    --cloud-provider:string 
] {
    #0. Get subnets info!
    let infra_outputs = {
        ingress_annotation_subnets: (infra output --cloud-provider=$cloud_provider --output-name=public_subnet_ids | from json | str join ",")
    }

    #1. Instalar ArgoCD
    argocd install --namespace=$namespace --infra-outputs=$infra_outputs --cloud-provider=$cloud_provider
}

def --env "argocd install" [
    --admin-enabled =   true
    --namespace:        string
    --infra-outputs:    record
    --cloud-provider:   string
] {
    #0. Create namespace (idempotent: tolerate an already-existing ns so a failed
    #   init can be re-run without manual cleanup).
    kubectl create ns $namespace --dry-run=client -o yaml | kubectl apply -f -

    #2. Define helm-vars
    argocd helm vars --admin-enabled=$admin_enabled --namespace=$namespace --infra-outputs=$infra_outputs --cloud-provider=$cloud_provider

    #3. Install with helm (upgrade --install: create-or-update so a re-run is safe)
    helm repo add argo https://argoproj.github.io/argo-helm
    helm upgrade --install argo-cd argo/argo-cd --version $env.argocd_version -f ($nu.temp-dir + "/argocd-vars.yaml")

    #4. Wait until it rollouts!
    kubectl -n argocd rollout status --watch --timeout=600s deployment/argo-cd-argocd-server
    kubectl -n argocd rollout status --watch --timeout=600s deployment.apps/argo-cd-argocd-repo-server
}

