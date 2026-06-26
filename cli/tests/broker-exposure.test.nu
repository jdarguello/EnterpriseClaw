# broker-exposure.test.nu — unit tests for the Keycloak + Session-Broker Istio exposure.
use std assert
source ../gitops/broker-exposure.nu
source harness.nu

def "broker-exposure-tests" [] {
    [
        # ---- pure generator: ingress Gateway ----
        { name: "gateway serves both hosts on istio-ingress", run: {||
            let g = (broker-exposure gateway --hosts=[ "auth.example.io" "broker.example.io" ])
            assert equal $g.kind "Gateway"
            assert equal $g.metadata.namespace "istio-ingress"
            assert equal ($g.spec.selector.istio) "ingress"
            assert equal ($g.spec.servers.0.hosts) [ "auth.example.io" "broker.example.io" ]
            assert equal ($g.spec.servers.0.port.number) 80
        }}

        # ---- pure generator: Keycloak VirtualService (full host) ----
        { name: "keycloak VS binds auth host to keycloak service on the shared gateway", run: {||
            let vs = (broker-exposure virtual-service --name="keycloak" --namespace="keycloak"
                --host="auth.example.io" --dest-host="keycloak.keycloak.svc.cluster.local" --dest-port=80 --prefix="/")
            assert equal $vs.kind "VirtualService"
            assert equal $vs.metadata.namespace "keycloak"
            assert equal ($vs.spec.hosts) [ "auth.example.io" ]
            assert equal ($vs.spec.gateways) [ "istio-ingress/session-broker-gateway" ]
            assert equal ($vs.spec.http.0.match.0.uri.prefix) "/"
            assert equal ($vs.spec.http.0.route.0.destination.host) "keycloak.keycloak.svc.cluster.local"
            assert equal ($vs.spec.http.0.route.0.destination.port.number) 80
        }}

        # ---- pure generator: broker VS is scoped to the OAuth callback only ----
        { name: "broker VS exposes only /auth/callback", run: {||
            let vs = (broker-exposure virtual-service --name="session-broker" --namespace="session-broker"
                --host="broker.example.io" --dest-host="session-broker.session-broker.svc.cluster.local" --dest-port=80 --prefix="/auth/callback")
            assert equal ($vs.spec.http.0.match.0.uri.prefix) "/auth/callback"
            assert equal ($vs.spec.http.0.route.0.destination.host) "session-broker.session-broker.svc.cluster.local"
        }}

        # ---- pure generator: shared-ALB Ingress admits both hosts on the istio-ingress service ----
        { name: "ingress admits auth+broker hosts on the shared ALB group", run: {||
            let ing = (broker-exposure ingress --auth-host="auth.example.io" --broker-host="broker.example.io"
                --subnets="subnet-a,subnet-b" --group-name="enterpriseclaw")
            assert equal $ing.kind "Ingress"
            assert equal $ing.metadata.namespace "istio-ingress"
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/scheme") "internet-facing"
            # the shared group.name is what folds this onto the existing platform ALB
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/group.name") "enterpriseclaw"
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/subnets") "subnet-a,subnet-b"
            assert equal ($ing.metadata.annotations | get "external-dns.alpha.kubernetes.io/hostname") "auth.example.io,broker.example.io"
            # auth host -> all paths; broker host -> callback only; both to the istio-ingress service
            assert equal ($ing.spec.rules.0.host) "auth.example.io"
            assert equal ($ing.spec.rules.0.http.paths.0.path) "/"
            assert equal ($ing.spec.rules.0.http.paths.0.backend.service.name) "istio-ingress"
            assert equal ($ing.spec.rules.1.host) "broker.example.io"
            assert equal ($ing.spec.rules.1.http.paths.0.path) "/auth/callback"
            assert equal ($ing.spec.rules.1.http.paths.0.backend.service.name) "istio-ingress"
        }}

        # ---- ingress group.name defaults to the shared platform group ----
        { name: "render defaults the ingress to the shared ALB group", run: {||
            let ing = (broker-exposure ingress --auth-host="auth.x" --broker-host="broker.x"
                --subnets="s-1" --group-name=(alb shared-group))
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/group.name") "enterpriseclaw"
        }}

        # ---- IO orchestrator: render derives hosts from the domain and writes the dir ----
        { name: "render writes resolved manifests under config/session-broker", run: {||
            let tmp = (make-tmpdir "broker-expose")
            mkdir $"($tmp)/gitops-config"
            let cwd = (pwd)
            cd $tmp
            broker-exposure render --private-path=gitops-config --domain="enterprise-claw.io" --subnets="subnet-aaa,subnet-bbb"

            let dir = $"($tmp)/gitops-config/config/session-broker"
            let g = (open $"($dir)/gateway.yaml")
            assert equal ($g.spec.servers.0.hosts) [ "auth.enterprise-claw.io" "broker.enterprise-claw.io" ]

            let vk = (open $"($dir)/virtual-service-keycloak.yaml")
            assert equal ($vk.spec.hosts) [ "auth.enterprise-claw.io" ]
            let vb = (open $"($dir)/virtual-service-broker.yaml")
            assert equal ($vb.spec.hosts) [ "broker.enterprise-claw.io" ]

            # the shared-ALB Ingress is rendered with the resolved hosts + injected subnets
            let ing = (open $"($dir)/ingress.yaml")
            assert equal ($ing.spec.rules.0.host) "auth.enterprise-claw.io"
            assert equal ($ing.spec.rules.1.host) "broker.enterprise-claw.io"
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/subnets") "subnet-aaa,subnet-bbb"
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/group.name") "enterpriseclaw"

            let k = (open $"($dir)/kustomization.yaml")
            assert equal $k.resources [ "ingress.yaml" "gateway.yaml" "virtual-service-keycloak.yaml" "virtual-service-broker.yaml" ]
            cd $cwd
            rm -rf $tmp
        }}

        # ---- host labels are configurable ----
        { name: "render honors custom subdomain labels", run: {||
            let tmp = (make-tmpdir "broker-expose-labels")
            mkdir $"($tmp)/gitops-config"
            let cwd = (pwd)
            cd $tmp
            broker-exposure render --private-path=gitops-config --domain="corp.net" --auth-label="login" --broker-label="oauth"
            let g = (open $"($tmp)/gitops-config/config/session-broker/gateway.yaml")
            assert equal ($g.spec.servers.0.hosts) [ "login.corp.net" "oauth.corp.net" ]
            cd $cwd
            rm -rf $tmp
        }}
    ]
}
