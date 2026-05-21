source aws/eks.nu

def --env "main cluster connect" [
    --cloud-provider:string         #Options: 'aws', 'azure', 'gcp'
    --region:string                 #Cloud region specification
    --cluster-name:string           #Name of the k8s cluster
] {
    if ($cloud_provider == "aws") {
        eks connect --region=$region --cluster-name=$cluster_name
    }
}