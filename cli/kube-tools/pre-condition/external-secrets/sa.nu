def "external-secrets sa irsa" [
    --namespace:    string
    --role-arn:     string
    --role-name:    string
    --save-path:    string
] {
    {
        apiVersion: "v1"
        automountServiceAccountToken: true
        kind: "ServiceAccount"
        metadata: {
            annotations: {
                "eks.amazonaws.com/role-arn": ($role_arn | str trim -c '"')
            }
            labels: {
                "app.kubernetes.io/instance": "external-secrets"
                "app.kubernetes.io/name": "external-secrets"
            }
            name: $role_name
            namespace: $namespace
        }
    } | to yaml | save $save_path --force
}