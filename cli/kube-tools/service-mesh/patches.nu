source ../../infra/outputs.nu
source ../../utils/generals.nu

def "istio components patch" [
    --infra-outputs:    record
    --kubetool:         string      #Name of the tool 
    --hostname:         string
] {
    #Ingress patch
    istio components patch ingress --hostname=$hostname --kubetool=$kubetool --infra-outputs=$infra_outputs

    #Gateway patch
    istio components patch gateway --hostname=$hostname --kubetool=$kubetool

    #Virtual-Service patch
    istio components patch vs --hostname=$hostname --kubetool=$kubetool
}

def "istio components patch vs" [
    --gitops-path-base: string
    --kubetool:         string
    --hostname:         string
] {
    #0. Definir path de instalación
    let path = $"gitops-config/config/istio/($kubetool)/vs-patch.yaml"
    let abs_path = abs-path --path=$path --replace-argument=""

    #1. Parchado del VS
    [{
        op: "replace"
        path: "/spec/hosts/0"
        value: $hostname
    }] | to yaml | save $abs_path --force
}

def --env "istio components patch gateway" [
    --gitops-path-base: string
    --kubetool:         string
    --hostname:         string
] {
    #0. Definir path de instalación
    let path = $"gitops-config/config/istio/($kubetool)/gateway-patch.yaml"
    let abs_path = abs-path --path=$path --replace-argument=""

    #1. Parchado del Gateway
    [{
        op: "replace"
        path: "/spec/servers/0/hosts/0"
        value: $hostname
    }] | to yaml | save $abs_path --force
}

def --env "istio components patch ingress" [
    --gitops-path-base: string
    --kubetool:         string
    --hostname:         string
    --infra-outputs:    record
] {
    #0. Definir path de instalación
    let path = $"gitops-config/config/istio/($kubetool)/ingress-patch.yaml"
    let abs_path = abs-path --path=$path --replace-argument=""

    #1. Ajuste del path
    mut backend_path = "/"
    if ($kubetool == "argo-events") {
        $backend_path = "/payload"
    }

    #2. Ingress-name
    let ingress_name = $"($kubetool)-istio-ingress"

    #3. Definición del Ingress
    {
        apiVersion: "networking.k8s.io/v1"
        kind: "Ingress"
        metadata: {
            annotations: {
                "alb.ingress.kubernetes.io/subnets": $infra_outputs.ingress_annotation_subnets
                "external-dns.alpha.kubernetes.io/hostname": $hostname
            }
            name: $ingress_name
            namespace: "istio-ingress"
        }
        spec: {
            rules: [{
                host: $hostname
                http: {
                    paths: [{
                        path: $backend_path
                        pathType: "Prefix"
                        backend: {
                            service: {
                                name: "istio-ingress"
                                port: {
                                    number: 80
                                }
                            }
                        }
                    }]
                }
            }]
        }
    } | to yaml | save $abs_path --force
}