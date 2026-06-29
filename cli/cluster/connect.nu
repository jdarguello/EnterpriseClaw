source aws/eks.nu
source local/kubeconfig.nu

def --env "main cluster connect" [
    --cloud-provider:string         #Options: 'aws', 'azure', 'gcp', 'local'
    --region:string                 #Cloud region specification
    --cluster-name:string           #Name of the k8s cluster
    --remote = "controlplane"       #local: ssh host alias of the control-plane VM
] {
    if ($cloud_provider == "aws") {
        eks connect --region=$region --cluster-name=$cluster_name
    } else if ($cloud_provider == "local") {
        # Local-testing path: link the UTM VM's kubeconfig instead of asking EKS for one.
        local connect --remote=$remote
    }
}