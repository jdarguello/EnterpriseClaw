source ../../utils/generals.nu

#Install external-secrets operator (ESO) via Helm through GitOps!
def "external-secrets bootstrap" [] {
    #1. Install ESO
    external-secrets bootstrap gitops

    #2. ESO Configuration
    external-secrets bootstrap config
}

#Configures External-Secrets Operator (ESO) with user's 
def "external-secrets bootstrap config" [
    --private-path="gitops-config/helm/kube-essentials/
] {
    #1. Change directory to private configuration
}

def "external-secrets bootstrap gitops" [] {
    #1. Get Helm-ESO path from GitOps directory
    let eso_path = abs-path --path="gitops/helm-eso.yaml" --replace-argument="/cli"

    #2. Install it via kubectl
    kubectl create -f $eso_path
}