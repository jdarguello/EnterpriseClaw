source ../utils/generals.nu
source ../infra/outputs.nu

def "alb-controller bootstrap" [
    --cloud-provider: string        #Options: 'aws'
] {
    #1. Load IaC Outputs!
    let infra_outputs = {
        clusterName: (infra output --output-name=cluster_name --cloud-provider=$cloud_provider | str trim -c '"'),
        serviceAccountName: "aws-load-balancer-controller",
        region: ($env.aws_region | str trim -c '"')
        vpcId: (infra output --output-name=vpc_id --cloud-provider=$cloud_provider | str trim -c '"'),
        saAnnotation: (infra output --output-name=alb-arn --cloud-provider=$cloud_provider | str trim -c '"')
    }

    #2. Patch Controller Config file
    alb-controller patch helm-vars --infra-outputs=$infra_outputs
}

def "alb-controller patch helm-vars" [
    infra-outputs: record
    gitops-path = "gitops-config/helm"
] {
    #1. Set helm-vars file path
    let path = $"($gitops_path)/kube-essentials/alb-controller/values.yaml"
    let abs_path = abs-path --path=$path

    #2. Generate Helm vars
    {
        "aws-load-balancer-controller": {
            clusterName: $infra_outputs.clusterName
            region: $infra_outputs.region
            vpcId: $infra_outputs.vpcId
            serviceAccount: {
                create: true
                name: $infra_outputs.serviceAccountName
                annotations: {
                    "eks.amazonaws.com/role-arn": $infra_outputs.saAnnotation
                }
            }
        }
    } | to yaml | save $abs_path --force
}