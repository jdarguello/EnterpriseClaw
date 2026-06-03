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

#Returns relative path as global. For instance: 'tmp/example.txt' converts it to '/Users/nicholas/Documents/EnterpriseClaw/cli/tmp/example.txt'
def "abs-path" [
    --path: string      #Relative path
    --replace-argument = "/EnterpriseClaw/cli"
] {
    return (pwd | str replace $replace_argument "" | append $path | str join "/")
}