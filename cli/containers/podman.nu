source ../opentofu/outputs.nu

def "containers init" [] {
    #1. Obtener información de podman
    let podman_machine_info = podman machine list --format json | from json

    #2. Si no hay ningún podman-machine
    if ($podman_machine_info | is-empty) {
        podman machine init

        podman machine start
    }

    #3. Si no hay ninguna máquina inicializada
    if ($podman_machine_info | get Running | where ($it == true) | is-empty) {
        podman machine start
    }
}

def "containers login" [
    --ecr-password: string
    --region: string
] {

    #1. Obtener account_id y definir login del ECR
    let account_id = (containers account_id)
    let login = $"($account_id).dkr.ecr.($region).amazonaws.com"
    
    #2. Ejecutar login
    $ecr_password | podman login --username AWS --password-stdin $login
}

def "containers build" [
    --tag: string
    --environment: string
    --prefix: string
    --action-name: string
] {
    #1. Nombre del artefacto en ECR
    let artifact_name = (containers artifact url --prefix=$prefix --action-name=$action_name --environment=$environment)

    #2. Operación de build
    podman build --platform linux/amd64 --manifest $"($artifact_name):($tag)" -t $"($artifact_name):amd64" .
    podman build --platform linux/arm64 --manifest $"($artifact_name):($tag)" -t $"($artifact_name):arm64" .
}

def --env "containers push" [
    --tag:string
    --environment: string
    --prefix: string
    --action-name: string
] {
    #1. Nombre del artefacto en ECR
    let artifact_name = (containers artifact url --prefix=$prefix --action-name=$action_name --environment=$environment)

    #2. Operación de push
    podman manifest push --all $"($artifact_name):($tag)" $"docker://($artifact_name):($tag)"
}

def "containers account_id" [] {
    return ($env.AWS_ROLE | split row "_" | get 0)
}

def "containers artifact url" [
    --environment: string
    --prefix: string
    --action-name: string
] {
    let repos_info = (opentofu output --path="../../infra" --environment=$environment --output-name="actions_registries_urls" | from json)
    return ($repos_info | get $"($prefix)/($action_name)")
}