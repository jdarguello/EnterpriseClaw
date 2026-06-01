def "external-secrets install" [] {
    #1. Install via Helm
    helm repo add external-secrets https://charts.external-secrets.io
    helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace 

    #3. Wait until rollout finishes!
    kubectl -n external-secrets rollout status --watch --timeout=600s deployment/external-secrets
    kubectl -n external-secrets rollout status --watch --timeout=600s deployment/external-secrets-webhook
    kubectl -n external-secrets rollout status --watch --timeout=600s deployment/external-secrets-cert-controller
}