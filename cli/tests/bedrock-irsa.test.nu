# bedrock-irsa.test.nu — unit tests for the Bedrock-IRSA AgentgatewayParameters generator (the
# per-tenant ARN injection onto the agentgateway LLM-gateway proxy SA). Pure-generator focused.
use std assert
source ../gitops/bedrock-irsa.nu
source harness.nu

def "bedrock-irsa-tests" [] {
    [
        # ---- pure generator: the whole AgentgatewayParameters object (design B) ----
        { name: "params emits AgentgatewayParameters with the role-arn annotation", run: {||
            let arn = "arn:aws:iam::123456789012:role/enterpriseclaw-bedrock-irsa"
            let m = (bedrock-irsa params --role-arn=$arn)
            assert equal $m.kind "AgentgatewayParameters"
            assert equal $m.apiVersion "agentgateway.dev/v1alpha1"
            assert equal $m.metadata.name "agentic-gw-params"
            assert equal $m.metadata.namespace "kagent"
            assert equal ($m.spec.serviceAccount.metadata.annotations | get "eks.amazonaws.com/role-arn") $arn
        }}

        # ---- design B: the object also carries the automount fix (the GOTCHA) ----
        { name: "params forces automountServiceAccountToken true (IRSA token volume)", run: {||
            let m = (bedrock-irsa params --role-arn="arn:aws:iam::1:role/x")
            assert equal ($m.spec.serviceAccount.spec.automountServiceAccountToken) true
        }}

        # ---- the ARN flows through verbatim (no mangling) ----
        { name: "params passes the ARN through unchanged", run: {||
            let arn = "arn:aws:iam::000000000000:role/tenant-foo-bedrock"
            let m = (bedrock-irsa params --role-arn=$arn)
            assert equal ($m.spec.serviceAccount.metadata.annotations | get "eks.amazonaws.com/role-arn") $arn
        }}

        # ---- pure generator: kustomization references the params file ----
        { name: "kustomization references agentgateway-parameters.yaml", run: {||
            let k = (bedrock-irsa kustomization)
            assert ("agentgateway-parameters.yaml" in $k.resources) "params file listed"
        }}

        # ---- pure generator: the Argo CD Application targets kagent + correct name ----
        { name: "app is an Argo Application landing in kagent after the trio install", run: {||
            let m = (bedrock-irsa app)
            assert equal $m.kind "Application"
            assert equal $m.metadata.name "agentic-bedrock-irsa"
            assert equal $m.metadata.namespace "argocd"
            assert equal ($m.spec.destination.namespace) "kagent"
            assert equal ($m.spec.source.path) "bedrock-irsa"
        }}

        # ---- repoURL is the FULL private-repo URL composed from ORG_NAME/CONFIG_REPO ----
        # (CONFIG_REPO is the bare repo NAME, not a URL — must match cli/gitops-config/main.yaml form.)
        { name: "app repoURL is https://github.com/<ORG_NAME>/<CONFIG_REPO>", run: {||
            with-env { ORG_NAME: "jdarguello", CONFIG_REPO: "EnterpriseClaw-Sandbox" } {
                let m = (bedrock-irsa app)
                assert equal ($m.spec.source.repoURL) "https://github.com/jdarguello/EnterpriseClaw-Sandbox"
            }
        }}

        # ---- the params object must reconcile AFTER the trio install (its CRD ships there) ----
        { name: "bedrock-irsa app sync-wave is at/after the agents install wave", run: {||
            let irsa  = ((bedrock-irsa app)            | get metadata.annotations | get "argocd.argoproj.io/sync-wave" | into int)
            let agents = ((app-of-apps agents-appset)  | get metadata.annotations | get "argocd.argoproj.io/sync-wave" | into int)
            assert ($irsa >= $agents) "params object must apply once the AgentgatewayParameters CRD exists"
        }}

        # ---- IO orchestrator analog: the params object is registered in the kustomization ----
        # (render reads a live infra output, so we test the pure registration path directly via the
        # shared app-of-apps merge — mirroring how render appends bedrock-irsa.yaml.)
        { name: "registering bedrock-irsa.yaml is idempotent + order-preserving", run: {||
            let base = { resources: [ "agents.yaml" "agentic.yaml" ] }
            let out = (app-of-apps merge-resources --kustomization=$base --add=[ "bedrock-irsa.yaml" ])
            assert equal $out.resources [ "agents.yaml" "agentic.yaml" "bedrock-irsa.yaml" ]
            let again = (app-of-apps merge-resources --kustomization=$out --add=[ "bedrock-irsa.yaml" ])
            assert equal $again.resources $out.resources
        }}
    ]
}
