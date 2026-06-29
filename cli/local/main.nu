# Local-testing provisioning — zero-to-running on the LOCAL cluster (the UTM "controlplane" VM),
# WITHOUT IaC/Terraform. This is the local counterpart of `main init` (cli/enterpriseclaw): it swaps
# the AWS substrate for the linked VM kubeconfig and skips the tofu-derived patches, but otherwise
# REUSES the same general functions (git-registry clone/push, app-of-apps register-*, gitops user repo)
# so the private repo we build here (jdarguello/EnterpriseClaw-Sandbox) is the very same config that a
# later cloud test consumes. Full platform parity minus AWS-only (ALB/DNS/ESO are tolerated as noise;
# reach services via `kubectl port-forward`).
source ../cluster/connect.nu
source ../git/main.nu
source ../gitops/app-of-apps.nu
source ../gitops/bootstrap.nu
source secrets.nu
source precondition.nu

# Zero-to-running on the local cluster.
def --env "main local init" [
    --git-provider = "github"
    --remote       = "controlplane"      # ssh host alias of the control-plane VM
] {
    #1. Link the local cluster (fetch the VM kubeconfig; sets $env.KUBECONFIG for this session)
    main cluster connect --cloud-provider=local --remote=$remote

    #2. Prepare the private repo: clone sandbox, localize Istio values, register the agentic platform
    #   + Session-Broker into the app-of-apps, push.
    main local kube-tools --git-provider=$git_provider

    #3. Gateway API CRDs (cloud: Istio supplies them; local: install explicitly before the apps sync)
    local precondition gateway-api

    #4. Secrets the cloud would sync via ESO+IRSA — created from AWS SM with the static .env creds.
    #   (argocd repo-creds must exist BEFORE the root app syncs so Argo can read the private repo.)
    main local secrets

    #5. Hand off to Argo CD: apply the app-of-apps root (Argo reconciles everything from here).
    main local gitops
}

# Private-repo preparation: the local analogue of `main kube-tools bootstrap` (minus the tofu patches
# and the AWS broker-exposure/keycloak-config, which need a real ALB/DNS).
def --env "main local kube-tools" [
    --git-provider = "github"
] {
    #0. Fresh clone of the private repo (the CLI always re-clones; remote is the source of truth)
    rm -rf gitops-config/
    git-registry clone --git-provider=$git_provider

    #1. Localize the Istio overlays (drop the EKS nodegroup nodeSelector → schedulable on the VM)
    local precondition istio

    #2. Register the agentic platform (kagent trio + agentic CRs) + the Session-Broker (general fns)
    app-of-apps register-agents
    app-of-apps register-session-broker

    #3. Push to the sandbox private repo
    git-registry push --git-provider=$git_provider --commit-message="local: agentic + broker + local istio values"
}

# Hand off the app-of-apps root to Argo CD (reuses the general function).
def "main local gitops" [] {
    gitops user repo --gitops-agent="argocd"
}
