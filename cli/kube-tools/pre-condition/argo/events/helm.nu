def "argo-events helm" [
    --namespace: string
    --node-labels: record
] {
    #1. node-labels and gitops-path
    let node_labels = k8s node-labels subnet-environments --cloud-provider=$cloud_provider

    let save_path = abs-path path="gitops-config/helm/argo/events/values.yaml" --replace-argument=""

    #2. Patch helm manifest
    {
        namespaceOverride: $namespace
        createAggregateRoles: true
        controller: {
            nodeSelector: {
                "eks.amazonaws.com/nodegroup": ($node_labels | get backend)
            }
        }
    } | to yaml | save $save_path --force
}