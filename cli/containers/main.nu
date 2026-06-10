source podman.nu

source ../aws/ecr.nu

#Conmpile and publish ALL actions contained in the given folder
def "main containers new-image all" [
    --path: string          #Path of community actions
] {
    ls $path | each {
        |item| if ($item.type == "dir") {
            #1. Obtains action metadata
            let action_name = ($item.name | split row "/" | get 2)
            let tag = containers get tag --path=$item.name

            #2. Compile and publishes the action
            main containers new-image --action-name=$action_name --tag=$tag
        }
    }
}

#Containerizes actions, pipelines and workflows from any git-provider (e. g., GitHub, Azure, GitLab, etc)
def "main containers new-image" [
    --marketplace = "github"                    #Actions marketplace. Options: 'github'
    --action-name = "create-github-app-token"   #Name of community action
    --prefix = "pipemanager"                    #Prefix name of the project
    --path-base = "../actions"                  #Path of actions
    --tag: string                               #Version of the image to compile

    --cloud-provider: string                    #Options: 'aws'
] {
    #1. Initializing Podman
    containers init

    #2. Podman login 
    let ecr_password = ecr password --region=$aws_region
    containers login --ecr-password=$ecr_password  --region=$aws_region

    #3. Action's path
    let current_path = pwd
    let action_path = $"($path_base)/($action_name)"
    cd $action_path

    #4. Image building
    containers build --environment=$environment --tag=$tag --prefix=$prefix --action-name=$action_name

    #5. Image publishing
    containers push --environment=$environment --tag=$tag --prefix=$prefix --action-name=$action_name

    #6. Returns to original path
    cd $current_path
}

def "containers get tag" [
    --path: string
] {
    #1. Cambio de directorio
    let current_dir = pwd
    cd $path

    #2. Obtenga el valor del tag
    let tag = open tag.txt

    #3. Regrese al path original
    cd $current_dir

    #4. Retorne el valor
    return $tag
}