def "containers destroy all" [
    --prefix = "pipemanager"
    --path: string
] {
    ls $path | each {
        |item| if ($item.type == "dir") {
            #1. Obtener nombre del repository
            let action_name = ($item.name | split row "/" | get 2)
            let repository_name = $"($prefix)/($action_name)"

            #2. Obtener los image-ids
            let image_ids = containers teardwon image ids --repository-name=$repository_name

            #3. Destruir contenido
            containers teardown image --repository-name=$repository_name --digests=$image_ids
        }
    }
}

def "containers teardown image" [
    --repository-name: string
    --digests:string
] {
    print $digests
    aws ecr batch-delete-image --repository-name $repository_name --image-ids ...$digests
}

def "containers teardwon image ids" [
    --repository-name: string
] {
    #1. Image Table
    let image_ids = aws ecr list-images --repository-name $repository_name --query 'imageIds[*]' --output json | from json

    #2. Image Digests
    mut imageDigest_list = []
    for image in ($image_ids | get imageDigest) {
        $imageDigest_list = $imageDigest_list | append $"imageDigest=($image)"
    }

    return $imageDigest_list
}