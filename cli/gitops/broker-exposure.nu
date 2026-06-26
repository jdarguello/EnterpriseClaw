# broker-exposure.nu — EnterpriseClaw-owned internet exposure for Keycloak + Session-Broker.
#
# The broker repo ships keycloak with `ingress.enabled: false` (ClusterIP only) and its own broker
# Ingress with a PLACEHOLDER host, so neither is reachable as-installed. EnterpriseClaw owns Istio
# (CLAUDE.md §5), so it provides the exposure here: an Istio Gateway + VirtualServices that route
# `auth.<domain>` -> Keycloak and `broker.<domain>/auth/callback` -> the broker, through the
# EXISTING internet-facing `istio-ingress` ALB (no new ALB; "reuse" per the chosen approach).
#
# These are written fully-resolved (real host from $env.domain_name) into the private repo's
# config/session-broker/, which the tenant `configs` ApplicationSet (globs config/*) auto-onboards
# as the `config-session-broker` Argo app. Resources carry explicit namespaces, so Argo honors them
# over the app's default destination namespace.
#
# SHARED ALB (done): the ingress generator below admits auth.<domain> + broker.<domain> on the
# SAME internet-facing ALB as the rest of the platform, via the shared
# `alb.ingress.kubernetes.io/group.name` (see `alb shared-group`). The existing argo-events / argocd
# / argo-workflows Ingresses carry the same group.name (cli/kube-tools/service-mesh/patches.nu), so
# the AWS Load Balancer Controller folds them all onto one ALB — host-based routing forwards each
# host to the istio-ingress service, and the Istio Gateway/VS take it from there. No new ALB.
#
# KEYCLOAK HOSTNAME (tenant-specific, configured from the private repo): Keycloak's external issuer
# (KC_HOSTNAME) and the broker's external OAuth URLs depend on $env.domain_name. The CLI supplies
# those tenant values from the private repo; the broker manifests must consume them through a
# parameter seam (the broker realm's redirectUris/webOrigins are a single Helm-rendered string and
# cannot be sub-string patched from here). See the Session-Broker integration notes / report.
source ../utils/generals.nu
source ../infra/outputs.nu

# ---------------------------------------------------------------------------
# Pure generators — return the Istio manifest as a Nushell record.
# ---------------------------------------------------------------------------

# Single ingress Gateway on the istio-ingress workload, serving both external hosts over HTTP
# (TLS terminates at the ALB; istio-ingress speaks HTTP behind it, matching the argo-events pattern).
def "broker-exposure gateway" [
    --hosts: list<string>           # e.g. [auth.<domain>, broker.<domain>]
] {
    {
        apiVersion: "networking.istio.io/v1beta1"
        kind: "Gateway"
        metadata: { name: "session-broker-gateway", namespace: "istio-ingress" }
        spec: {
            selector: { istio: "ingress" }
            servers: [
                { port: { number: 80, name: "http", protocol: "HTTP" }, hosts: $hosts }
            ]
        }
    }
}

# One VirtualService binding an external host (on the shared Gateway) to an in-cluster service.
def "broker-exposure virtual-service" [
    --name:      string
    --namespace: string             # the route lives next to its destination workload
    --host:      string             # external host, e.g. auth.<domain>
    --dest-host: string             # ClusterIP FQDN, e.g. keycloak.keycloak.svc.cluster.local
    --dest-port: int
    --prefix   = "/"                # URI prefix to match (broker is scoped to /auth/callback)
] {
    {
        apiVersion: "networking.istio.io/v1beta1"
        kind: "VirtualService"
        metadata: { name: $name, namespace: $namespace }
        spec: {
            hosts: [ $host ]
            gateways: [ "istio-ingress/session-broker-gateway" ]
            http: [
                {
                    match: [ { uri: { prefix: $prefix } } ]
                    route: [ { destination: { host: $dest_host, port: { number: $dest_port } } } ]
                }
            ]
        }
    }
}

# AWS ALB Ingress that admits the broker/Keycloak hosts on the SHARED platform ALB and forwards
# them to the istio-ingress gateway service. Mirrors the argo-events Ingress shape (TLS terminates
# at the ALB; istio-ingress speaks HTTP behind it) and carries the shared `group.name` so it reuses
# the one ALB instead of provisioning another. external-dns publishes both hostnames at that ALB.
def "broker-exposure ingress" [
    --auth-host:    string          # auth.<domain>   -> Keycloak (all paths)
    --broker-host:  string          # broker.<domain> -> Session-Broker (callback only)
    --subnets:      string          # comma-joined public subnet IDs for ALB placement
    --group-name:   string          # shared ALB IngressGroup name
    --callback-path = "/auth/callback"
] {
    {
        apiVersion: "networking.k8s.io/v1"
        kind: "Ingress"
        metadata: {
            name: "session-broker-istio-ingress"
            namespace: "istio-ingress"
            annotations: {
                "alb.ingress.kubernetes.io/scheme": "internet-facing"
                "alb.ingress.kubernetes.io/target-type": "ip"
                "alb.ingress.kubernetes.io/backend-protocol": "HTTP"
                "alb.ingress.kubernetes.io/listen-ports": '[{"HTTPS":443}, {"HTTP":80}]'
                "alb.ingress.kubernetes.io/ssl-redirect": "443"
                "alb.ingress.kubernetes.io/group.name": $group_name
                "alb.ingress.kubernetes.io/subnets": $subnets
                "external-dns.alpha.kubernetes.io/hostname": $"($auth_host),($broker_host)"
            }
        }
        spec: {
            ingressClassName: "alb"
            rules: [
                {
                    host: $auth_host
                    http: { paths: [ { path: "/", pathType: "Prefix", backend: { service: { name: "istio-ingress", port: { number: 80 } } } } ] }
                }
                {
                    host: $broker_host
                    http: { paths: [ { path: $callback_path, pathType: "Prefix", backend: { service: { name: "istio-ingress", port: { number: 80 } } } } ] }
                }
            ]
        }
    }
}

# kustomization for the config/session-broker/ directory.
def "broker-exposure kustomization" [] {
    { resources: [ "ingress.yaml" "gateway.yaml" "virtual-service-keycloak.yaml" "virtual-service-broker.yaml" ] }
}

# ---------------------------------------------------------------------------
# IO orchestrator — write the resolved exposure manifests into the private repo clone.
# ---------------------------------------------------------------------------

def "broker-exposure render" [
    --private-path  = "gitops-config"
    --domain:       string                                              # $env.domain_name, e.g. enterprise-claw.io
    --subnets       = ""                                                # comma-joined public subnet IDs (ALB placement)
    --group-name    = ""                                                # shared ALB IngressGroup; defaults to (alb shared-group)
    --auth-label    = "auth"                                            # auth.<domain>   -> Keycloak
    --broker-label  = "broker"                                         # broker.<domain> -> Session-Broker
    --keycloak-svc  = "keycloak.keycloak.svc.cluster.local"
    --keycloak-port = 80
    --broker-svc    = "session-broker.session-broker.svc.cluster.local"
    --broker-port   = 80
] {
    let auth_host   = $"($auth_label).($domain)"
    let broker_host = $"($broker_label).($domain)"
    let group = (if ($group_name | is-empty) { alb shared-group } else { $group_name })
    let dir = (abs-path --path=$"($private_path)/config/session-broker" --replace-argument="")
    mkdir $dir

    (broker-exposure ingress --auth-host=$auth_host --broker-host=$broker_host
        --subnets=$subnets --group-name=$group
    ) | to yaml | save $"($dir)/ingress.yaml" --force

    (broker-exposure gateway --hosts=[$auth_host $broker_host]) | to yaml | save $"($dir)/gateway.yaml" --force

    (broker-exposure virtual-service --name="keycloak" --namespace="keycloak"
        --host=$auth_host --dest-host=$keycloak_svc --dest-port=$keycloak_port --prefix="/"
    ) | to yaml | save $"($dir)/virtual-service-keycloak.yaml" --force

    (broker-exposure virtual-service --name="session-broker" --namespace="session-broker"
        --host=$broker_host --dest-host=$broker_svc --dest-port=$broker_port --prefix="/auth/callback"
    ) | to yaml | save $"($dir)/virtual-service-broker.yaml" --force

    (broker-exposure kustomization) | to yaml | save $"($dir)/kustomization.yaml" --force
}
