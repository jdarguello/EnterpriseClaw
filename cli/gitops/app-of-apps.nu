# app-of-apps.nu — registers the agentic platform (kagent trio + agentic CRs) and the
# Session-Broker into the tenant's private app-of-apps, so `enterpriseclaw init` brings them up
# via GitOps (Argo CD) rather than imperative `kubectl apply`.
#
# Design: the CLI's job is to GENERATE the private repo's overlays (see CLAUDE.md §5). These
# commands write three Argo CD definition files into the freshly-cloned private repo and register
# them in its root kustomization.yaml, BEFORE the kube-tools push. Argo's `main` app-of-apps then
# renders them on first sync.
#
# The generated definitions point straight at the PUBLIC repo (no per-tenant overlay needed — the
# trio install and agentic CRs are framework-static; Bedrock/GitHub auth is via out-of-band Secrets).
# The Session-Broker app points at the broker repo's own bootstrap ApplicationSet.
#
# Pure generators (return records, no IO) are unit-tested in cli/tests/; the IO orchestrators just
# serialize them with `to yaml | save` and merge the kustomization.
source ../utils/generals.nu

# ---------------------------------------------------------------------------
# Pure generators — return the Argo CD manifest as a Nushell record.
# ---------------------------------------------------------------------------

# kagent trio INSTALLER ApplicationSet — git directory generator over gitops/helm/agents/* in the
# PUBLIC repo (kagent[-crds], kmcp[-crds], agentgateway[-crds]). Mirrors the proven dry-run appset.
def "app-of-apps agents-appset" [
    --public-repo = "https://github.com/jdarguello/EnterpriseClaw"
    --revision    = "main"
    --sync-wave   = "1"                # best-effort: install trio before the agentic CRs (wave 2)
] {
    {
        apiVersion: "argoproj.io/v1alpha1"
        kind: "ApplicationSet"
        metadata: {
            name: "agents"
            namespace: "argocd"
            annotations: { "argocd.argoproj.io/sync-wave": $sync_wave }
        }
        spec: {
            generators: [
                { git: { repoURL: $public_repo, revision: $revision, directories: [ { path: "gitops/helm/agents/*" } ] } }
            ]
            template: {
                metadata: {
                    name: "agents-{{path.basename}}"
                    labels: { "app.kubernetes.io/part-of": "agents" }
                }
                spec: {
                    project: "default"
                    source: { repoURL: $public_repo, targetRevision: $revision, path: "{{path}}" }
                    destination: { server: "https://kubernetes.default.svc", namespace: "argocd" }
                    syncPolicy: { automated: { prune: true, selfHeal: true } }
                }
            }
        }
    }
}

# agentic CRs ApplicationSet — git directory generator over gitops/agentic/* in the PUBLIC repo
# (the kagent Agents, MCPServers, ModelConfig, gateways). All land in the `kagent` namespace.
def "app-of-apps agentic-appset" [
    --public-repo = "https://github.com/jdarguello/EnterpriseClaw"
    --revision    = "main"
    --sync-wave   = "2"                # after the trio install (wave 1) so the CRDs exist
] {
    {
        apiVersion: "argoproj.io/v1alpha1"
        kind: "ApplicationSet"
        metadata: {
            name: "agentic"
            namespace: "argocd"
            annotations: { "argocd.argoproj.io/sync-wave": $sync_wave }
        }
        spec: {
            generators: [
                { git: { repoURL: $public_repo, revision: $revision, directories: [ { path: "gitops/agentic/*" } ] } }
            ]
            template: {
                metadata: {
                    name: "agentic-{{path.basename}}"
                    labels: { "app.kubernetes.io/part-of": "agentic" }
                }
                spec: {
                    project: "default"
                    source: { repoURL: $public_repo, targetRevision: $revision, path: "{{path}}" }
                    destination: { server: "https://kubernetes.default.svc", namespace: "kagent" }
                    # ESO 0.10.5's GithubAccessToken admission silently prunes these fields,
                    # so the live object can never match git — ignore or the app sits OutOfSync
                    ignoreDifferences: [
                        {
                            group: "generators.external-secrets.io"
                            kind: "GithubAccessToken"
                            jsonPointers: ["/spec/repositories" "/spec/permissions"]
                        }
                    ]
                    syncPolicy: { automated: { prune: true, selfHeal: true } }
                }
            }
        }
    }
}

# Session-Broker Application — applies ONLY the broker repo's gitops/bootstrap.yaml (its
# `session-broker-platform` ApplicationSet, which in turn installs keycloak/redis/dapr/broker).
# `directory.include` scopes the source path to that single file so the other gitops/ files
# (helm values, kustomize bases) are not applied as loose manifests.
#
# NAME = "session-broker-bootstrap" (NOT "session-broker"): the AppSet this installs generates
# a child Application literally named "session-broker" (the broker overlay). If this installer
# were also named "session-broker" the two would be the SAME argocd object owned by two
# controllers (this app-of-apps + the AppSet) — they flip-flop the source and eventually
# deadlock on the resources-finalizer (observed: the object wedged in Terminating, pruning
# keycloak/redis/dapr with it). The distinct installer name keeps the two objects separate.
def "app-of-apps session-broker-app" [
    --broker-repo = "https://github.com/jdarguello/Session-Broker"
    --revision    = "main"
    --sync-wave   = "1"
] {
    {
        apiVersion: "argoproj.io/v1alpha1"
        kind: "Application"
        metadata: {
            name: "session-broker-bootstrap"
            namespace: "argocd"
            annotations: { "argocd.argoproj.io/sync-wave": $sync_wave }
        }
        spec: {
            project: "default"
            source: {
                repoURL: $broker_repo
                targetRevision: $revision
                path: "gitops"
                directory: { include: "bootstrap.yaml" }
            }
            destination: { server: "https://kubernetes.default.svc", namespace: "argocd" }
            syncPolicy: { automated: { prune: true, selfHeal: true } }
        }
    }
}

# Idempotent kustomization merge — appends new resource filenames, de-duplicating while preserving
# the existing order (existing entries first). Pure: takes/returns a parsed record.
def "app-of-apps merge-resources" [
    --kustomization: record         # parsed kustomization.yaml
    --add: list<string>             # resource filenames to ensure present
] {
    let existing = ($kustomization.resources? | default [])
    let merged = ($existing | append $add | uniq)
    $kustomization | upsert resources $merged
}

# ---------------------------------------------------------------------------
# IO orchestrators — write the generated definitions into the private repo clone.
# ---------------------------------------------------------------------------

# Register the kagent trio installer + the agentic CRs into the private app-of-apps.
def "app-of-apps register-agents" [
    --private-path = "gitops-config"
] {
    let base = (abs-path --path=$private_path --replace-argument="")
    (app-of-apps agents-appset)  | to yaml | save $"($base)/agents.yaml" --force
    (app-of-apps agentic-appset) | to yaml | save $"($base)/agentic.yaml" --force
    app-of-apps ensure-resources --base=$base --add=["agents.yaml" "agentic.yaml"]
}

# Register the Session-Broker bootstrap Application into the private app-of-apps.
def "app-of-apps register-session-broker" [
    --private-path = "gitops-config"
] {
    let base = (abs-path --path=$private_path --replace-argument="")
    (app-of-apps session-broker-app) | to yaml | save $"($base)/session-broker.yaml" --force
    app-of-apps ensure-resources --base=$base --add=["session-broker.yaml"]
}

# Read -> merge -> write the private root kustomization.yaml.
def "app-of-apps ensure-resources" [
    --base: string
    --add:  list<string>
] {
    let kpath = $"($base)/kustomization.yaml"
    let current = (open $kpath)
    let updated = (app-of-apps merge-resources --kustomization=$current --add=$add)
    $updated | to yaml | save $kpath --force
}
