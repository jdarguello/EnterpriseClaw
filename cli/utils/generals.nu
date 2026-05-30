#Returns the exact labels for for 'frontend' (public subnets) and 'backend' (private subnets) deployments
def "k8s node-labels subnet-environments" [
    --cloud-provider:string
] {
    let node_info = (kubectl get nodes -L eks.amazonaws.com/nodegroup -o json | from json)
    let response:record = null
    if ($cloud_provider == "aws") {
        response = {
            frontend: ($node_info | get items | get metadata | get labels | get "eks.amazonaws.com/nodegroup" | where ($it =~ "frontend") | get 0)
            backend: ($node_info | get items | get metadata | get labels | get "eks.amazonaws.com/nodegroup" | where ($it =~ "backend") | get 0)
        } 
    }
    return response
}