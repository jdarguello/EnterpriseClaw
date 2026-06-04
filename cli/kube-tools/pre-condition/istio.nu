source ../../utils/generals.nu

def "istio bootstrap" [
    --gitops-helm-path:     string
    --cloud-provider:   string
] {
    #1. Helm-vars of istiod
    istio bootstrap istiod --gitops-helm-path=$gitops_helm_path --cloud-provider=$cloud_provider
    
    #2. Helm-vars of istio-gateway
    istio bootstrap gateway --gitops-helm-path=$gitops_helm_path --cloud-provider=$cloud_provider
}

def "istio bootstrap istiod" [
    --gitops-helm-path: string
    --cloud-provider:   string
] {
    #1. Path de instalación
    let path = $"($gitops_helm_path)/kube-tools/istio-system/values.yaml"
    let abs_path = abs-path --path=$path --replace-argument=""

    #2. Definición de Helm-vars
    let node_labels = k8s node-labels subnet-environments --cloud-provider=$cloud_provider

    let istiod_vars = {
        nodeSelector: {
            "eks.amazonaws.com/nodegroup": ($node_labels | get backend)
        }
        global: {
            waypoint: {
                nodeSelector: {
                    "eks.amazonaws.com/nodegroup": ($node_labels | get backend)
                }
            }
        }
    }

    #3. Update del Helm-vars
    mut istio_vars = open $abs_path
    $istio_vars = $istio_vars | update istiod $istiod_vars
    $istio_vars | to yaml | save $abs_path --force
}

def "istio bootstrap gateway" [
    --gitops-helm-path: string
    --cloud-provider:   string
] {
    #1. Path de instalación
    let path = $"($gitops_helm_path)/kube-tools/istio-ingress/values.yaml"
    let abs_path = abs-path --path=$path --replace-argument=""

    #2. Definición de Helm-vars
    let node_labels = k8s node-labels subnet-environments --cloud-provider=$cloud_provider

    let gateway_vars = {
        nodeSelector: {
            "eks.amazonaws.com/nodegroup": ($node_labels | get backend)
        }
    }

    #3. Update del Helm-vars
    mut istio_vars = open $abs_path
    $istio_vars = $istio_vars | update gateway $gateway_vars
    $istio_vars | to yaml | save $abs_path --force
}