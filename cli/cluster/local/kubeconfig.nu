# local connect — links the LOCAL k8s cluster (the UTM "controlplane" VM) into the CLI session.
#
# This is the local-testing counterpart to `eks connect` (cluster/aws/eks.nu): instead of asking a
# cloud provider for a kubeconfig, we fetch the VM's admin kubeconfig over SSH. The VM's API server
# is reachable from the host (its kubeconfig already embeds a host-routable server URL, e.g.
# https://192.168.64.2:6443), so the copied file works as-is from inside Devbox — no tunnel needed.
#
# The kubeconfig is stashed in a gitignored, CLI-local file and `$env.KUBECONFIG` is pointed at it
# for the rest of the orchestration session, so every downstream `kubectl`/`helm`/`argo` general
# function targets the local cluster. No AWS, no OpenTofu — this is what the local provisioning path
# uses in place of `main cluster setup` + `eks connect`.
source ../../utils/generals.nu

def --env "local connect" [
    --remote = "controlplane"                 # ssh host alias of the control-plane VM
    --remote-kubeconfig = "~/.kube/config"    # kubeconfig path on the VM
    --kubeconfig-path = ".kube/local.config"  # host-side stash, relative to cli/ (gitignored)
] {
    #1. Resolve the host-side destination (under cli/) and ensure its directory exists
    let dest = (abs-path --path=$kubeconfig_path --replace-argument="")
    mkdir ($dest | path dirname)

    #2. Fetch the VM's admin kubeconfig over SSH
    let cfg = (^ssh $remote $"cat ($remote_kubeconfig)")
    $cfg | save $dest --force

    #3. Point this session's tooling (kubectl/helm/argo) at the local cluster
    $env.KUBECONFIG = $dest

    #4. Verify connectivity
    print $"Linked local cluster via '($remote)' -> ($dest)"
    print $"Context: (kubectl config current-context)"
    kubectl get nodes
}
