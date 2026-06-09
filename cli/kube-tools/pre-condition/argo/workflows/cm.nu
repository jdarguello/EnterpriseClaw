

def "argo-workflows bootstrap patch cm" [
    --cloud-provider: string
] {
    #1. Get dynamic config
    mut artifact_repository = {}
    if ($cloud_provider == "aws") {
        $artifact_repository = argo-workflows bootstrap patch cm aws
    }

    #2. Patch manifest
    argo-workflows bootstrap patch cm manifest --artifact-repository=$artifact_repository
}

def "argo-workflows bootstrap patch cm manifest" [
    --artifact-repository: record
] {
    #0. Patch path
    let path = $"gitops-config/config/argo-workflows/cm-patch.yaml"
    let abs_path = abs-path --path=$path --replace-argument=""

    #1. Patch manifest
    {
        apiVersion: "v1"
        kind: "ConfigMap"
        metadata: {
            annotations: {
                "workflows.argoproj.io/default-artifact-repository": default-artifact-repository
            }
            name: artifact-repository
            namespace: argo
        }
        data: {
            "default-artifact-repository": ($artifact_repository | to yaml)
        }
    } | to yaml | save $abs_path --force
}

def --env "argo-workflows bootstrap patch cm aws" [] {
    #1. Infra outputs - storage
    let bucket_name = (infra output --cloud-provider="aws" --output-name="pipeline-storage-name")

    #2. Dynamic config
    return {
        artifactRepository: {
            archiveLogs: true
        }
        s3: {
            bucket: $bucket_name
            keyPrefix: "argo-artifacts"
            endpoint: "s3.amazonaws.com"
            region: $env.region
            insecure: false
            useSDKCreds: true
        }
    }
}