# kagent-exposure.nu — EnterpriseClaw-owned internet exposure for the kagent dashboard UI.
#
# The kagent chart ships its dashboard as the `kagent-ui` ClusterIP Service (port 8080) in the
# `kagent` namespace, with NO Gateway/VirtualService/Ingress, so the dashboard is not reachable
# from outside the cluster as-installed. EnterpriseClaw owns Istio (CLAUDE.md §5), so it provides
# the exposure here: an Istio Gateway + VirtualService that route `ai-platform.<domain>` -> the
# kagent UI Service, through the EXISTING internet-facing `istio-ingress` ALB (no new ALB —
# "reuse" via the shared ALB IngressGroup, exactly like broker-exposure.nu).
#
# These are written fully-resolved (real host from $env.domain_name) into the private repo's
# config/kagent-ui/, which the tenant `configs` ApplicationSet (globs config/*) auto-onboards
# as the `config-kagent-ui` Argo app. Resources carry explicit namespaces, so Argo honors them
# over the app's default destination namespace.
#
# SHARED ALB: the ingress generator below admits ai-platform.<domain> on the SAME internet-facing
# ALB as the rest of the platform, via the shared `alb.ingress.kubernetes.io/group.name`
# (see `alb shared-group`). The existing argo-events / argocd / argo-workflows / session-broker
# Ingresses carry the same group.name, so the AWS Load Balancer Controller folds them all onto one
# ALB — host-based routing forwards each host to the istio-ingress service, and the Istio
# Gateway/VS take it from there. No new ALB. external-dns publishes the hostname at that ALB.
source ../utils/generals.nu
source ../infra/outputs.nu

# ---------------------------------------------------------------------------
# Pure generators — return the Istio manifest as a Nushell record.
# ---------------------------------------------------------------------------

# Ingress Gateway on the istio-ingress workload, serving the kagent dashboard host over HTTP
# (TLS terminates at the ALB; istio-ingress speaks HTTP behind it, matching broker-exposure).
def "kagent-exposure gateway" [
    --hosts: list<string>           # e.g. [ai-platform.<domain>]
] {
    {
        apiVersion: "networking.istio.io/v1beta1"
        kind: "Gateway"
        metadata: { name: "kagent-ui-gateway", namespace: "istio-ingress" }
        spec: {
            selector: { istio: "ingress" }
            servers: [
                { port: { number: 80, name: "http", protocol: "HTTP" }, hosts: $hosts }
            ]
        }
    }
}

# VirtualService binding the dashboard host (on the kagent-ui Gateway) to the kagent UI service.
def "kagent-exposure virtual-service" [
    --name:      string
    --namespace: string             # the route lives next to its destination workload
    --host:      string             # external host, e.g. ai-platform.<domain>
    --dest-host: string             # ClusterIP FQDN, e.g. kagent-ui.kagent.svc.cluster.local
    --dest-port: int
    --prefix   = "/"                # URI prefix to match
] {
    {
        apiVersion: "networking.istio.io/v1beta1"
        kind: "VirtualService"
        metadata: { name: $name, namespace: $namespace }
        spec: {
            hosts: [ $host ]
            gateways: [ "istio-ingress/kagent-ui-gateway" ]
            http: [
                {
                    match: [ { uri: { prefix: $prefix } } ]
                    route: [ { destination: { host: $dest_host, port: { number: $dest_port } } } ]
                }
            ]
        }
    }
}

# AWS ALB Ingress that admits the kagent dashboard host on the SHARED platform ALB and forwards it
# to the istio-ingress gateway service. Mirrors the broker-exposure Ingress shape (TLS terminates
# at the ALB; istio-ingress speaks HTTP behind it) and carries the shared `group.name` so it reuses
# the one ALB instead of provisioning another. external-dns publishes the hostname at that ALB.
def "kagent-exposure ingress" [
    --ui-host:      string          # ai-platform.<domain> -> kagent dashboard (all paths)
    --subnets:      string          # comma-joined public subnet IDs for ALB placement
    --group-name:   string          # shared ALB IngressGroup name
] {
    {
        apiVersion: "networking.k8s.io/v1"
        kind: "Ingress"
        metadata: {
            name: "kagent-ui-istio-ingress"
            namespace: "istio-ingress"
            annotations: {
                "alb.ingress.kubernetes.io/scheme": "internet-facing"
                "alb.ingress.kubernetes.io/target-type": "ip"
                "alb.ingress.kubernetes.io/backend-protocol": "HTTP"
                "alb.ingress.kubernetes.io/listen-ports": '[{"HTTPS":443}, {"HTTP":80}]'
                "alb.ingress.kubernetes.io/ssl-redirect": "443"
                # Health-check Istio's status port: the istio-ingress gateway 404s on a bare `/`,
                # so the ALB default `/`→200 check marks targets unhealthy → 503. See CLAUDE.md §6.
                "alb.ingress.kubernetes.io/healthcheck-port": "15021"
                "alb.ingress.kubernetes.io/healthcheck-path": "/healthz/ready"
                "alb.ingress.kubernetes.io/success-codes": "200"
                "alb.ingress.kubernetes.io/group.name": $group_name
                "alb.ingress.kubernetes.io/subnets": $subnets
                "external-dns.alpha.kubernetes.io/hostname": $ui_host
            }
        }
        spec: {
            ingressClassName: "alb"
            rules: [
                {
                    host: $ui_host
                    http: { paths: [ { path: "/", pathType: "Prefix", backend: { service: { name: "istio-ingress", port: { number: 80 } } } } ] }
                }
            ]
        }
    }
}

# kustomization for the config/kagent-ui/ directory.
def "kagent-exposure kustomization" [] {
    { resources: [ "ingress.yaml" "gateway.yaml" "virtual-service.yaml" ] }
}

# ---------------------------------------------------------------------------
# IO orchestrator — write the resolved exposure manifests into the private repo clone.
# ---------------------------------------------------------------------------

def "kagent-exposure render" [
    --private-path  = "gitops-config"
    --domain:       string                                              # $env.domain_name, e.g. enterprise-claw.io
    --subnets       = ""                                                # comma-joined public subnet IDs (ALB placement)
    --group-name    = ""                                                # shared ALB IngressGroup; defaults to (alb shared-group)
    --ui-label      = "ai-platform"                                    # ai-platform.<domain> -> kagent dashboard
    --kagent-svc    = "kagent-ui.kagent.svc.cluster.local"
    --kagent-port   = 8080
] {
    let ui_host = $"($ui_label).($domain)"
    let group = (if ($group_name | is-empty) { alb shared-group } else { $group_name })
    let dir = (abs-path --path=$"($private_path)/config/kagent-ui" --replace-argument="")
    mkdir $dir

    (kagent-exposure ingress --ui-host=$ui_host --subnets=$subnets --group-name=$group
    ) | to yaml | save $"($dir)/ingress.yaml" --force

    (kagent-exposure gateway --hosts=[$ui_host]) | to yaml | save $"($dir)/gateway.yaml" --force

    (kagent-exposure virtual-service --name="kagent-ui" --namespace="kagent"
        --host=$ui_host --dest-host=$kagent_svc --dest-port=$kagent_port --prefix="/"
    ) | to yaml | save $"($dir)/virtual-service.yaml" --force

    (kagent-exposure kustomization) | to yaml | save $"($dir)/kustomization.yaml" --force
}
