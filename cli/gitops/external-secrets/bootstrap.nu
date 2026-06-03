source ../../utils/generals.nu

#Install external-secrets operator (ESO) via Helm through GitOps!
def "external-secrets bootstrap" [] {

    #1. Get Helm-ESO path from GitOps directory
    let eso_path = abs-path --path="gitops/helm-eso.yaml" --replace-argument="/cli"

    #2. Install it via kubectl
    kubectl create -f $eso_path
}