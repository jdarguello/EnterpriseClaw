# app-of-apps.test.nu — unit tests for the agentic-platform + Session-Broker app-of-apps wiring.
use std assert
source ../gitops/app-of-apps.nu
source harness.nu

def "app-of-apps-tests" [] {
    [
        # ---- pure generator: kagent-trio installer ApplicationSet ----
        { name: "agents-appset shape & defaults", run: {||
            let m = (app-of-apps agents-appset)
            assert equal $m.kind "ApplicationSet"
            assert equal $m.metadata.name "agents"
            assert equal $m.metadata.namespace "argocd"
            assert equal ($m.metadata.annotations | get "argocd.argoproj.io/sync-wave") "1"
            assert equal ($m.spec.generators.0.git.directories.0.path) "gitops/helm/agents/*"
            assert equal ($m.spec.generators.0.git.repoURL) "https://github.com/jdarguello/EnterpriseClaw"
            assert equal ($m.spec.template.spec.destination.namespace) "argocd"
            assert equal ($m.spec.template.spec.syncPolicy.automated.prune) true
        }}

        # ---- pure generator: agentic CRs ApplicationSet ----
        { name: "agentic-appset shape, wave after install, lands in kagent ns", run: {||
            let m = (app-of-apps agentic-appset)
            assert equal $m.metadata.name "agentic"
            assert equal ($m.metadata.annotations | get "argocd.argoproj.io/sync-wave") "2"
            assert equal ($m.spec.generators.0.git.directories.0.path) "gitops/agentic/*"
            assert equal ($m.spec.template.spec.destination.namespace) "kagent"
        }}

        # ---- agentic must sync AFTER the trio install (CRDs first) ----
        { name: "agentic sync-wave is greater than agents sync-wave", run: {||
            let agents  = ((app-of-apps agents-appset)  | get metadata.annotations | get "argocd.argoproj.io/sync-wave" | into int)
            let agentic = ((app-of-apps agentic-appset) | get metadata.annotations | get "argocd.argoproj.io/sync-wave" | into int)
            assert ($agentic > $agents) "agentic CRs must reconcile after the trio CRDs/controllers"
        }}

        # ---- pure generator: Session-Broker Application ----
        { name: "session-broker-app targets broker repo bootstrap only", run: {||
            let m = (app-of-apps session-broker-app)
            assert equal $m.kind "Application"
            assert equal $m.metadata.name "session-broker"
            assert equal ($m.spec.source.repoURL) "https://github.com/jdarguello/Session-Broker"
            assert equal ($m.spec.source.path) "gitops"
            assert equal ($m.spec.source.directory.include) "bootstrap.yaml"
        }}

        # ---- fork support: public-repo override flows through both URLs ----
        { name: "agents-appset honors a custom --public-repo", run: {||
            let m = (app-of-apps agents-appset --public-repo="https://github.com/acme/Fork")
            assert equal ($m.spec.generators.0.git.repoURL) "https://github.com/acme/Fork"
            assert equal ($m.spec.template.spec.source.repoURL) "https://github.com/acme/Fork"
        }}

        # ---- pure merge: idempotent, order-preserving ----
        { name: "merge-resources appends without duplicating, preserves order", run: {||
            let base = { resources: [ "helm.yaml" "helm-istio.yaml" "configs.yaml" ] }
            let out = (app-of-apps merge-resources --kustomization=$base --add=[ "agents.yaml" "agentic.yaml" "configs.yaml" ])
            assert equal $out.resources [ "helm.yaml" "helm-istio.yaml" "configs.yaml" "agents.yaml" "agentic.yaml" ]
            # re-merging the same additions changes nothing
            let again = (app-of-apps merge-resources --kustomization=$out --add=[ "agents.yaml" "agentic.yaml" ])
            assert equal $again.resources $out.resources
        }}

        { name: "merge-resources tolerates a kustomization with no resources key", run: {||
            let out = (app-of-apps merge-resources --kustomization={} --add=[ "agents.yaml" ])
            assert equal $out.resources [ "agents.yaml" ]
        }}

        # ---- IO orchestrator: register-agents writes files + registers them ----
        { name: "register-agents writes appsets and updates kustomization", run: {||
            let tmp = (make-tmpdir "register-agents")
            seed-private-repo $tmp [ "helm.yaml" "helm-istio.yaml" "configs.yaml" ]
            let cwd = (pwd)
            cd $tmp
            app-of-apps register-agents --private-path=gitops-config

            let agents  = (open $"($tmp)/gitops-config/agents.yaml")
            let agentic = (open $"($tmp)/gitops-config/agentic.yaml")
            assert equal $agents.metadata.name "agents"
            assert equal $agentic.metadata.name "agentic"

            let k = (open $"($tmp)/gitops-config/kustomization.yaml")
            assert ("agents.yaml"  in $k.resources) "agents.yaml registered"
            assert ("agentic.yaml" in $k.resources) "agentic.yaml registered"
            cd $cwd
            rm -rf $tmp
        }}

        # ---- IO orchestrator: register-session-broker ----
        { name: "register-session-broker writes app and registers it", run: {||
            let tmp = (make-tmpdir "register-broker")
            seed-private-repo $tmp [ "helm.yaml" "configs.yaml" ]
            let cwd = (pwd)
            cd $tmp
            app-of-apps register-session-broker --private-path=gitops-config

            let app = (open $"($tmp)/gitops-config/session-broker.yaml")
            assert equal $app.kind "Application"
            let k = (open $"($tmp)/gitops-config/kustomization.yaml")
            assert ("session-broker.yaml" in $k.resources) "session-broker.yaml registered"
            cd $cwd
            rm -rf $tmp
        }}

        # ---- IO is idempotent across re-runs (re-clone safety) ----
        { name: "re-running register-agents does not duplicate kustomization entries", run: {||
            let tmp = (make-tmpdir "register-idem")
            seed-private-repo $tmp [ "helm.yaml" ]
            let cwd = (pwd)
            cd $tmp
            app-of-apps register-agents --private-path=gitops-config
            app-of-apps register-agents --private-path=gitops-config
            let k = (open $"($tmp)/gitops-config/kustomization.yaml")
            assert equal ($k.resources | where $it == "agents.yaml" | length) 1
            cd $cwd
            rm -rf $tmp
        }}
    ]
}
