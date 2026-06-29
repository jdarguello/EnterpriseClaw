# Local-testing preconditioning — the substitute for the tofu-derived `main kube-tools preconditioning`
# patches. We deliberately keep the AWS-only apps (alb-controller, external-dns, the ALB Ingresses)
# untouched — on the local cluster they are harmless "noise" and services are reached via
# `kubectl port-forward`, so their DNS/ALB wiring simply never fires. The only patches that MUST be
# localized are the ones that would otherwise block scheduling or admission.
source ../utils/generals.nu

# Overwrite the PRIVATE Istio value overlays so istiod / ingress / waypoint schedule on the VM.
# The committed values pin `nodeSelector: eks.amazonaws.com/nodegroup: <backend>` — an EKS-only label
# absent on the local nodes, which would leave every Istio pod Pending. The private values are layered
# on top of the public base via the multi-source `$private-values` overlay, so emptying them here
# (default scheduling) is enough; the public chart defaults take over.
def "local precondition istio" [
    --base = "gitops-config/helm-istio"
] {
    let root = (abs-path --path=$base --replace-argument="")
    {} | to yaml | save $"($root)/istio-system/values-istiod.yaml" --force
    {} | to yaml | save $"($root)/istio-ingress/values.yaml" --force
}

# Install the upstream Gateway API CRDs. Istio supplies these in the cloud; on the bare VM the
# agentgateway / kagent Gateways (gateway.networking.k8s.io) need them present before those apps sync.
# Reuses the dry-run manifest from the public tree. Idempotent (kubectl apply).
def "local precondition gateway-api" [
    --manifest = "gitops/dry-run/gateway-api-crds.yaml"
] {
    let path = (abs-path --path=$manifest --replace-argument="/cli")
    ^kubectl apply -f $path
}
