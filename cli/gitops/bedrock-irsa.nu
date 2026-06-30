# bedrock-irsa.nu — EnterpriseClaw supplies the TENANT-specific Bedrock IRSA role ARN onto the
# agentgateway LLM-gateway proxy ServiceAccount, the per-tenant half of converting the Bedrock hop
# to IRSA (CLAUDE.md §2.2: agentgateway's SA holds `bedrock:InvokeModel`, least-privilege).
#
# WHY HERE / WHY THE PRIVATE REPO:
#   The agentic ApplicationSet renders gitops/agentic/* straight from the PUBLIC repo with NO
#   per-tenant overlay seam, and the public tree must stay ARN-free. The established pattern (see
#   broker-keycloak-config.nu / kagent-exposure.nu) is: the CLI generates a fully-resolved overlay
#   into the freshly-cloned PRIVATE repo and registers it in the root app-of-apps before the push,
#   so Argo CD reconciles it on first sync. So the cleanest non-colliding path is the CLI delivering
#   the ARN-bearing object through the PRIVATE repo.
#
# DESIGN CHOICE (B) — CLI OWNS THE WHOLE AgentgatewayParameters OBJECT:
#   Two ownership options were on the table (see the GOAL coordination note):
#     (A) the public tree ships `agentic-gw-params` (with the automount fix) and the CLI only PATCHES
#         its role-arn annotation in the private flow; or
#     (B) the public tree ships NO params object and the CLI GENERATES the entire object
#         (role-arn annotation + automount fix) into the private repo.
#   We implement (B): there is no clean per-tenant patch seam over the public agentic tree, and a
#   whole CLI-owned object in the private repo avoids any two-controller collision. If the GitOps task
#   instead lands the params object in the public tree (A), this generator's object would COLLIDE
#   (two definitions of the same `agentic-gw-params`) — so reconcile by either dropping the public
#   object OR switching this to a kustomize/patch overlay. *** Coordinate with the GitOps task. ***
#
# CONTRACT (fixed, do not change without coordinating):
#   - infra root output name : `bedrock_irsa_arn`  (the Bedrock IRSA role ARN)
#   - params object          : kind AgentgatewayParameters, apiVersion agentgateway.dev/v1alpha1,
#                              name `agentic-gw-params`, namespace `kagent`
#   - the Gateway `agentic-gw` (gitops/agentic/llm-gateway/gateway.yaml) references it via
#     spec.infrastructure.parametersRef -> name `agentic-gw-params` (the GitOps task ships that ref)
#   - SA annotation set       : spec.serviceAccount.metadata.annotations."eks.amazonaws.com/role-arn"
#   - automount fix (the GOTCHA — controller-generated SA has automount false + no AWS token volume):
#                              spec.serviceAccount.spec.automountServiceAccountToken: true
#
# The ARN is NOT a secret, but it is live infra output — handled like the other infra outputs
# (read via `infra output`, str-trimmed), never hand-edited into the tree.
source ../utils/generals.nu
source ../infra/outputs.nu
source app-of-apps.nu        # reuses `app-of-apps ensure-resources` (idempotent kustomization merge)

# ---------------------------------------------------------------------------
# Pure generators — return the manifest(s) as a Nushell record. Unit-tested in cli/tests/.
# ---------------------------------------------------------------------------

# The complete AgentgatewayParameters object the agentgateway controller consumes when provisioning
# the `agentic-gw` proxy: it sets the Bedrock IRSA role-arn annotation on the proxy ServiceAccount
# AND flips automount on (so the pod gets an AWS web-identity token volume — without this the SA's
# IRSA is inert). Design (B): this is the WHOLE object (annotation + automount), CLI-owned.
def "bedrock-irsa params" [
    --role-arn:  string             # the Bedrock IRSA role ARN (infra output bedrock_irsa_arn)
    --name       = "agentic-gw-params"
    --namespace  = "kagent"
] {
    {
        apiVersion: "agentgateway.dev/v1alpha1"
        kind: "AgentgatewayParameters"
        metadata: { name: $name, namespace: $namespace }
        spec: {
            serviceAccount: {
                metadata: {
                    annotations: {
                        "eks.amazonaws.com/role-arn": $role_arn
                    }
                }
                # GOTCHA fix: the controller-generated SA defaults automount to false (no AWS token
                # volume on the pod), which makes IRSA inert. Force it on.
                spec: {
                    automountServiceAccountToken: true
                }
            }
        }
    }
}

# Argo CD Application that syncs the CLI-generated params overlay (the dir below) into the `kagent`
# namespace. Distinct, self-contained app (not folded into the agentic AppSet, which globs the PUBLIC
# repo) so the private ARN-bearing object lands cleanly. Sync-wave AFTER the trio install (which
# ships the AgentgatewayParameters CRD) so the object's apply does not race the CRD.
def "bedrock-irsa app" [
    --revision    = "main"
    --path        = "bedrock-irsa"
    --sync-wave   = "2"                # after the trio install (gitops agents-appset is wave 1)
] {
    {
        apiVersion: "argoproj.io/v1alpha1"
        kind: "Application"
        metadata: {
            name: "agentic-bedrock-irsa"
            namespace: "argocd"
            annotations: { "argocd.argoproj.io/sync-wave": $sync_wave }
        }
        spec: {
            project: "default"
            source: {
                # The private repo itself — the CLI wrote the params overlay into <repo>/bedrock-irsa.
                # CONFIG_REPO is the bare repo NAME; compose the full URL the same way the rest of the
                # CLI does (cli/git/github/main.nu remote / cli/gitops-config/main.yaml).
                repoURL: $"https://github.com/($env.ORG_NAME | str trim -c '"')/($env.CONFIG_REPO | str trim -c '"')"
                targetRevision: $revision
                path: $path
            }
            destination: { server: "https://kubernetes.default.svc", namespace: "kagent" }
            syncPolicy: { automated: { prune: true, selfHeal: true } }
        }
    }
}

# kustomization for the private-repo bedrock-irsa/ overlay directory.
def "bedrock-irsa kustomization" [] {
    { resources: [ "agentgateway-parameters.yaml" ] }
}

# ---------------------------------------------------------------------------
# IO orchestrator — read the live ARN, write the params overlay + register the Application.
# ---------------------------------------------------------------------------

# Generate the AgentgatewayParameters overlay (with the tenant's Bedrock IRSA ARN) into the private
# repo clone and register a dedicated Argo CD Application for it in the root app-of-apps. Called from
# kube-tools bootstrap (after register-agents) BEFORE the push, exactly like the other overlays.
def "bedrock-irsa render" [
    --cloud-provider: string
    --private-path  = "gitops-config"
] {
    # Read the Bedrock IRSA role ARN from live infra output (same idiom as external-dns / vars).
    let role_arn = (infra output --output-name=bedrock_irsa_arn --cloud-provider=$cloud_provider | str trim -c '"')

    let base = (abs-path --path=$private_path --replace-argument="")
    let dir = $"($base)/bedrock-irsa"
    mkdir $dir

    (bedrock-irsa params --role-arn=$role_arn
    ) | to yaml | save $"($dir)/agentgateway-parameters.yaml" --force
    (bedrock-irsa kustomization) | to yaml | save $"($dir)/kustomization.yaml" --force

    # Register the Application in the private root app-of-apps (reuses app-of-apps' idempotent merge).
    (bedrock-irsa app) | to yaml | save $"($base)/bedrock-irsa.yaml" --force
    app-of-apps ensure-resources --base=$base --add=["bedrock-irsa.yaml"]
}
