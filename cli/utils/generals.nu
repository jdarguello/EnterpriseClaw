#Returns the exact labels for for 'frontend' (public subnets) and 'backend' (private subnets) deployments
def "k8s node-labels subnet-environments" [
    --cloud-provider:string
] {
    let node_info = (kubectl get nodes -L eks.amazonaws.com/nodegroup -o json | from json)
    print $node_info
    if ($cloud_provider == "aws") {
        return {
            frontend: ($node_info | get items | get metadata | get labels | get "eks.amazonaws.com/nodegroup" | where ($it =~ "frontend") | get 0)
            backend: ($node_info | get items | get metadata | get labels | get "eks.amazonaws.com/nodegroup" | where ($it =~ "backend") | get 0)
        } 
    }
    return null
}

# Shared AWS ALB IngressGroup name. Every internet-facing Ingress that carries the
# `alb.ingress.kubernetes.io/group.name: <this>` annotation is folded by the AWS Load
# Balancer Controller onto ONE shared ALB (host-based routing differentiates them),
# instead of provisioning a separate ALB per Ingress. This is how the broker/Keycloak
# hosts "reuse" the existing internet-facing ALB rather than standing up a new one.
# Cluster-scoped constant for the demo (single cluster); make it per-cluster-unique
# (e.g. include the cluster name) before sharing one AWS account across clusters.
def "alb shared-group" [] {
    "enterpriseclaw"
}

#Returns relative path as global. For instance: 'tmp/example.txt' converts it to '/Users/nicholas/Documents/EnterpriseClaw/cli/tmp/example.txt'
def "abs-path" [
    --path: string      #Relative path
    --replace-argument = "/EnterpriseClaw/cli"
] {
    return (pwd | str replace $replace_argument "" | append $path | str join "/")
}

# List files from a path
def "list-files" [
    --path:             string      
    --except-filenames:  string         #When specified, it will pop any file with this name from the result. You can concat several filenames using the '|' operator.
    --filter-format=    "yaml|yml"      #When specified, it will only bring files from this format. You can concat different file formats using '|' operator.
] {
    #1. Absolute path
    let abs_path = abs-path --path=$path --replace-argument=""

    #2. Get filters
    let filters = ($filter_format | split row "|")

    #3. List files matching any filter
    let files = (ls $abs_path | where type == "file" | where { |f| ($filters | any { |ext| ($f.name | str ends-with $".($ext)") }) } | get name)

    #4. Exclude by filename if provided
    if ($except_filenames != null) {
        let excluded = ($except_filenames | split row "|")
        return ($files | where { |f| not ($excluded | any { |name| ($f | str ends-with $"/($name)") }) })
    }
    return $files
}