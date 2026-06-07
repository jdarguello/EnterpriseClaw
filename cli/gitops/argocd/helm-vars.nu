source ../../utils/generals.nu

def --env "argocd helm vars" [
    --admin-enabled
    --namespace:        string
    --infra-outputs:    record
    --cloud-provider:   string
] {

    #1. Dynamic variables from IaC
    let node_labels = k8s node-labels subnet-environments --cloud-provider=$cloud_provider

    #2. Helm vars - ETIQUETA DE FRONTEND!
    {
        namespaceOverride: $namespace
        global: {
            domain: $"gitops.($env.domain_name)"
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
            podLabels: {
                "role": "backend"
            }
        }
        applicationSet: {
            nodeSelector: {
                "eks.amazonaws.com/nodegroup": ($node_labels | get backend)
            }
            podLabels: {
                "role": "backend"
            }
        }
        redis: {
            nodeSelector: {
                "eks.amazonaws.com/nodegroup": ($node_labels | get backend)
            }
            podLabels: {
                "role": "backend"
            }
        }
        notifications: {
            nodeSelector: {
                "eks.amazonaws.com/nodegroup": ($node_labels | get backend)
            }
            podLabels: {
                "role": "backend"
            }
        }
        repoServer: {
            nodeSelector: {
                "eks.amazonaws.com/nodegroup": ($node_labels | get backend)
            }
            podLabels: {
                "role": "backend"
            }
        }
        server: {
            nodeSelector: {
                "eks.amazonaws.com/nodegroup": ($node_labels | get frontend)
            }
            podLabels: {
                "role": "frontend"
            }
            tolerations: [
                {
                    key: "role"
                    operator: "Equal"
                    value: "frontend"
                    effect: "NoSchedule"
                }
            ]
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
                    "external-dns.alpha.kubernetes.io/hostname": $"gitops.($env.domain_name)"
                }
                aws: {
                    serviceType: ClusterIP
                    backendProtocolVersion: GRPC
                }
            }
        }
    } | to yaml | save ($nu.temp-dir + "/argocd-vars.yaml") --force
}