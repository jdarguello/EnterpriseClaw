def "alb-controller bootstrap" [] {
    #1. Load IaC Outputs!
    let infra_outputs = {
        clusterName: (infra output --output-name=eks_name --environment=$environment | str trim -c '"'),
        serviceAccountName: "aws-load-balancer-controller",
        region: ($env.aws_region | str trim -c '"')
        vpcId: (infra output --output-name=eks-vpc-id --environment=$environment | str trim -c '"'),
        saAnnotation: (infra output --output-name=alb-arn --environment=$environment | str trim -c '"')
    }

    #2. Patch Controller Config file
    alb-controller patch helm-vars --tofu-outputs=$tofu_outputs
}

def "alb-controller patch helm-vars" [
    infra-outputs: record
] {
    #1. Definir path para el Helm vars file
    let path = $"($gitops_path)/kube-essentials/alb-controller/values-($environment).yaml"
    let abs_path = abs-path --path=$path

    #2. Generar el Helm vars
    {
        "aws-load-balancer-controller": {
            clusterName: $tofu_outputs.clusterName
            region: $tofu_outputs.region
            vpcId: $tofu_outputs.vpcId
            serviceAccount: {
                create: true
                name: $tofu_outputs.serviceAccountName
                annotations: {
                    "eks.amazonaws.com/role-arn": $tofu_outputs.saAnnotation
                }
            }
        }
    } | to yaml | save $abs_path --force
}