# kagent-exposure.test.nu — unit tests for the kagent dashboard UI Istio exposure.
use std assert
source ../gitops/kagent-exposure.nu
source harness.nu

def "kagent-exposure-tests" [] {
    [
        # ---- pure generator: ingress Gateway ----
        { name: "gateway serves the ui host on istio-ingress", run: {||
            let g = (kagent-exposure gateway --hosts=[ "ai-platform.example.io" ])
            assert equal $g.kind "Gateway"
            assert equal $g.metadata.name "kagent-ui-gateway"
            assert equal $g.metadata.namespace "istio-ingress"
            assert equal ($g.spec.selector.istio) "ingress"
            assert equal ($g.spec.servers.0.hosts) [ "ai-platform.example.io" ]
            assert equal ($g.spec.servers.0.port.number) 80
        }}

        # ---- pure generator: kagent UI VirtualService ----
        { name: "VS binds ui host to kagent-ui service on the kagent-ui gateway", run: {||
            let vs = (kagent-exposure virtual-service --name="kagent-ui" --namespace="kagent"
                --host="ai-platform.example.io" --dest-host="kagent-ui.kagent.svc.cluster.local" --dest-port=8080 --prefix="/")
            assert equal $vs.kind "VirtualService"
            assert equal $vs.metadata.namespace "kagent"
            assert equal ($vs.spec.hosts) [ "ai-platform.example.io" ]
            assert equal ($vs.spec.gateways) [ "istio-ingress/kagent-ui-gateway" ]
            assert equal ($vs.spec.http.0.match.0.uri.prefix) "/"
            assert equal ($vs.spec.http.0.route.0.destination.host) "kagent-ui.kagent.svc.cluster.local"
            assert equal ($vs.spec.http.0.route.0.destination.port.number) 8080
        }}

        # ---- pure generator: shared-ALB Ingress admits the ui host on the istio-ingress service ----
        { name: "ingress admits the ui host on the shared ALB group", run: {||
            let ing = (kagent-exposure ingress --ui-host="ai-platform.example.io"
                --subnets="subnet-a,subnet-b" --group-name="enterpriseclaw")
            assert equal $ing.kind "Ingress"
            assert equal $ing.metadata.name "kagent-ui-istio-ingress"
            assert equal $ing.metadata.namespace "istio-ingress"
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/scheme") "internet-facing"
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/target-type") "ip"
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/backend-protocol") "HTTP"
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/ssl-redirect") "443"
            # the shared group.name is what folds this onto the existing platform ALB
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/group.name") "enterpriseclaw"
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/subnets") "subnet-a,subnet-b"
            assert equal ($ing.metadata.annotations | get "external-dns.alpha.kubernetes.io/hostname") "ai-platform.example.io"
            # ui host -> all paths to the istio-ingress service
            assert equal ($ing.spec.rules.0.host) "ai-platform.example.io"
            assert equal ($ing.spec.rules.0.http.paths.0.path) "/"
            assert equal ($ing.spec.rules.0.http.paths.0.backend.service.name) "istio-ingress"
            assert equal ($ing.spec.rules.0.http.paths.0.backend.service.port.number) 80
        }}

        # ---- ingress group.name defaults to the shared platform group ----
        { name: "ingress carries the shared ALB group", run: {||
            let ing = (kagent-exposure ingress --ui-host="ai-platform.x"
                --subnets="s-1" --group-name=(alb shared-group))
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/group.name") "enterpriseclaw"
        }}

        # ---- IO orchestrator: render derives the host from the domain and writes the dir ----
        { name: "render writes resolved manifests under config/kagent-ui", run: {||
            let tmp = (make-tmpdir "kagent-expose")
            mkdir $"($tmp)/gitops-config"
            let cwd = (pwd)
            cd $tmp
            kagent-exposure render --private-path=gitops-config --domain="enterprise-claw.io" --subnets="subnet-aaa,subnet-bbb"

            let dir = $"($tmp)/gitops-config/config/kagent-ui"
            let g = (open $"($dir)/gateway.yaml")
            assert equal ($g.spec.servers.0.hosts) [ "ai-platform.enterprise-claw.io" ]

            let vs = (open $"($dir)/virtual-service.yaml")
            assert equal ($vs.spec.hosts) [ "ai-platform.enterprise-claw.io" ]
            assert equal ($vs.spec.http.0.route.0.destination.host) "kagent-ui.kagent.svc.cluster.local"
            assert equal ($vs.spec.http.0.route.0.destination.port.number) 8080

            # the shared-ALB Ingress is rendered with the resolved host + injected subnets
            let ing = (open $"($dir)/ingress.yaml")
            assert equal ($ing.spec.rules.0.host) "ai-platform.enterprise-claw.io"
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/subnets") "subnet-aaa,subnet-bbb"
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/group.name") "enterpriseclaw"
            assert equal ($ing.metadata.annotations | get "external-dns.alpha.kubernetes.io/hostname") "ai-platform.enterprise-claw.io"

            let k = (open $"($dir)/kustomization.yaml")
            assert equal $k.resources [ "ingress.yaml" "gateway.yaml" "virtual-service.yaml" ]
            cd $cwd
            rm -rf $tmp
        }}

        # ---- host label is configurable ----
        { name: "render honors a custom subdomain label", run: {||
            let tmp = (make-tmpdir "kagent-expose-label")
            mkdir $"($tmp)/gitops-config"
            let cwd = (pwd)
            cd $tmp
            kagent-exposure render --private-path=gitops-config --domain="corp.net" --ui-label="dashboard"
            let g = (open $"($tmp)/gitops-config/config/kagent-ui/gateway.yaml")
            assert equal ($g.spec.servers.0.hosts) [ "dashboard.corp.net" ]
            cd $cwd
            rm -rf $tmp
        }}
    ]
}
