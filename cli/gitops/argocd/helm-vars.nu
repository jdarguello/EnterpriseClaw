source ../../utils/generals.nu

def --env "argo cd helm vars" [
    --admin-enabled:    boolean
    --namespace:        string
    --infra-outputs: record
] {

    #1. Dynamic variables from IaC
    let node_labels = k8s node-labels subnet-environments

    #2. Helm vars
    {
        namespaceOverride: $namespace
        global: {
            domain: $env.dns_data_gitops_url
        }
        configs: {
            cm: {
                "admin.enabled": $admin_enabled
            }
            params: {
                "server.insecure": true
            }
        }
        controller: {
            nodeSelector: {
                "eks.amazonaws.com/nodegroup": ($node_labels | get backend)
            }
        }
        applicationSet: {
            nodeSelector: {
                "eks.amazonaws.com/nodegroup": ($node_labels | get backend)
            }
        }
        redis: {
            nodeSelector: {
                "eks.amazonaws.com/nodegroup": ($node_labels | get backend)
            }
        }
        notifications: {
            nodeSelector: {
                "eks.amazonaws.com/nodegroup": ($node_labels | get frontend)
            }
        }
        repoServer: {
            nodeSelector: {
                "eks.amazonaws.com/nodegroup": ($node_labels | get frontend)
            }
        }
        server: {
            nodeSelector: {
                "eks.amazonaws.com/nodegroup": ($node_labels | get frontend)
            }
            ingress: {
                enabled: false
                ingressClassName: alb
                controller: aws
                annotations: {
                    "alb.ingress.kubernetes.io/scheme": "internet-facing"
                    "alb.ingress.kubernetes.io/target-type": "ip"
                    "alb.ingress.kubernetes.io/backend-protocol": HTTP
                    "alb.ingress.kubernetes.io/subnets": $infra_outputs.ingress_annotation_subnets
                    "alb.ingress.kubernetes.io/listen-ports": '[{"HTTPS":443}, {"HTTP":80}]'
                    "alb.ingress.kubernetes.io/ssl-redirect": '443'
                    "external-dns.alpha.kubernetes.io/hostname": $env.dns_data_gitops_url
                }
                aws: {
                    serviceType: ClusterIP
                    backendProtocolVersion: GRPC
                }
            }
        }
    } | to yaml | save tmp/argocd-vars.yaml --force
}