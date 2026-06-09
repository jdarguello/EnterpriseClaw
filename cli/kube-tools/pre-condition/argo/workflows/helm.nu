source ../../../../utils/generals.nu

def --env "argo-workflows helm" [
    --namespace =       "argo"
    --cloud-provider:   string
    --infra-outputs:    record
] {
    #0. Patch path
    let path = $"gitops-config/helm/argo/workflows/values.yaml"
    let abs_path = abs-path --path=$path --replace-argument=""

    #1. Dynamic env & extraEnv contents
    let env_content = {
        name: "AWS_DEFAULT_REGION"
        value: $env.region
    }

    let node_labels = k8s node-labels subnet-environments --cloud-provider=$cloud_provider

    #2. Definición de variables y almacenamiento
    {
        namespaceOverride: $namespace
        controller: {
            extraEnv: [$env_content]
            nodeSelector: {
                "eks.amazonaws.com/nodegroup": ($node_labels | get backend)
            }
        }
        executor: {
            env: [$env_content]
        }
        mainContainer: {
            env: [$env_content]
        }
        server: {
            secure: false
            authModes: ["server"]
            extraEnv: [$env_content]
            nodeSelector: {
                "eks.amazonaws.com/nodegroup": ($node_labels | get frontend)
            }
        } 
    } | to yaml | save $abs_path --force
}