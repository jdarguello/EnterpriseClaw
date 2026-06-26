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
# CROSS-REPO COUPLING (cannot be fixed from here): Keycloak's KC_HOSTNAME / frontend-url must be
# pinned to https://auth.<domain> in the BROKER repo's keycloak values, or issued tokens' `iss`
# claim will not match what agentgateway validates. Flagged for the Session-Broker repo.
#
# OPEN (ALB host-admission): for the ALB to forward auth/broker hosts to istio-ingress it must admit
# them (a shared-ALB Ingress via alb.ingress.kubernetes.io/group.name, or extra host rules on the
# argo-events Ingress). That touches the proven webhook ALB path, so it is deliberately NOT done here
# — these Istio routes are inert until that lands. See the report / follow-up.
source ../utils/generals.nu

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

# kustomization for the config/session-broker/ directory.
def "broker-exposure kustomization" [] {
    { resources: [ "gateway.yaml" "virtual-service-keycloak.yaml" "virtual-service-broker.yaml" ] }
}

# ---------------------------------------------------------------------------
# IO orchestrator — write the resolved exposure manifests into the private repo clone.
# ---------------------------------------------------------------------------

def "broker-exposure render" [
    --private-path  = "gitops-config"
    --domain:       string                                              # $env.domain_name, e.g. enterprise-claw.io
    --auth-label    = "auth"                                            # auth.<domain>   -> Keycloak
    --broker-label  = "broker"                                         # broker.<domain> -> Session-Broker
    --keycloak-svc  = "keycloak.keycloak.svc.cluster.local"
    --keycloak-port = 80
    --broker-svc    = "session-broker.session-broker.svc.cluster.local"
    --broker-port   = 80
] {
    let auth_host   = $"($auth_label).($domain)"
    let broker_host = $"($broker_label).($domain)"
    let dir = (abs-path --path=$"($private_path)/config/session-broker" --replace-argument="")
    mkdir $dir

    (broker-exposure gateway --hosts=[$auth_host $broker_host]) | to yaml | save $"($dir)/gateway.yaml" --force

    (broker-exposure virtual-service --name="keycloak" --namespace="keycloak"
        --host=$auth_host --dest-host=$keycloak_svc --dest-port=$keycloak_port --prefix="/"
    ) | to yaml | save $"($dir)/virtual-service-keycloak.yaml" --force

    (broker-exposure virtual-service --name="session-broker" --namespace="session-broker"
        --host=$broker_host --dest-host=$broker_svc --dest-port=$broker_port --prefix="/auth/callback"
    ) | to yaml | save $"($dir)/virtual-service-broker.yaml" --force

    (broker-exposure kustomization) | to yaml | save $"($dir)/kustomization.yaml" --force
}
