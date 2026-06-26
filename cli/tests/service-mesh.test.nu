# service-mesh.test.nu — unit tests for the per-tenant Istio Ingress patch.
#
# Focus: the shared-ALB change. Every kubetool Ingress (argocd / argo-workflows / argo-events) must
# carry the shared `alb.ingress.kubernetes.io/group.name`, so the AWS Load Balancer Controller folds
# them — together with the broker/Keycloak Ingress — onto ONE ALB instead of one per tool.
use std assert
source ../kube-tools/service-mesh/patches.nu
source harness.nu

def "service-mesh-tests" [] {
    [
        # ---- argo-events: shared group + subnets + host, /payload backend ----
        { name: "events ingress patch joins the shared ALB group", run: {||
            let tmp = (make-tmpdir "svc-mesh-events")
            mkdir $"($tmp)/gitops-config/config/istio/argo-events"
            let cwd = (pwd)
            cd $tmp
            istio components patch ingress --kubetool="argo-events" --hostname="events.example.io" --infra-outputs={ ingress_annotation_subnets: "subnet-1,subnet-2" }
            let ing = (open "gitops-config/config/istio/argo-events/ingress-patch.yaml")
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/group.name") "enterpriseclaw"
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/subnets") "subnet-1,subnet-2"
            assert equal ($ing.metadata.annotations | get "external-dns.alpha.kubernetes.io/hostname") "events.example.io"
            assert equal ($ing.spec.rules.0.host) "events.example.io"
            assert equal ($ing.spec.rules.0.http.paths.0.path) "/payload"   # webhook payload path
            cd $cwd
            rm -rf $tmp
        }}

        # ---- non-events tools share the SAME group (so it is truly one ALB) and use root path ----
        { name: "argocd ingress patch shares the same group name + root path", run: {||
            let tmp = (make-tmpdir "svc-mesh-argocd")
            mkdir $"($tmp)/gitops-config/config/istio/argocd"
            let cwd = (pwd)
            cd $tmp
            istio components patch ingress --kubetool="argocd" --hostname="gitops.example.io" --infra-outputs={ ingress_annotation_subnets: "s" }
            let ing = (open "gitops-config/config/istio/argocd/ingress-patch.yaml")
            assert equal ($ing.metadata.annotations | get "alb.ingress.kubernetes.io/group.name") "enterpriseclaw"
            assert equal ($ing.spec.rules.0.http.paths.0.path) "/"
            cd $cwd
            rm -rf $tmp
        }}

        # ---- the broker Ingress (broker-exposure) must use this SAME group constant ----
        { name: "shared group constant is stable", run: {||
            assert equal (alb shared-group) "enterpriseclaw"
        }}
    ]
}
