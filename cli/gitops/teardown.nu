def "main teardown gitops" [
    --gitops-agent: string
] { 
    if ($gitops_agent == "argocd") {
        argo-project teardown
    }
}


def "argo-project teardown" [] {
    #1. Delete 'main' Application
    kubectl delete application -n argocd main

    #2. Delete 'configs' ApplicationSet with ALB and DNS configurations
    kubectl delete applicationset -n argocd configs
}