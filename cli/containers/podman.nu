# containers/podman.nu — podman build/login/push mechanics for the actions images.
#
# Fixed 2026-07-01: removed the dead `source ../opentofu/outputs.nu` (that dir doesn't exist; the
# infra output helper lives at cli/infra/outputs.nu and the binary is `tofu`, not `opentofu`) and the
# `$env.AWS_ROLE` / `$env.environment` couplings. The ECR repo URI is now constructed directly from
# the account/region-derived registry host (aws/ecr.nu) + the framework repo name `${project}/<name>`,
# which matches how the image-registries tofu module auto-creates the repos (glob of actions/*/README.md
# → repo `${project}/<action-name>`). No hand-edited tfvars, no tofu-output dependency.

source ../aws/ecr.nu

# The ECR project prefix, matching cli/infra/vars.nu: "${COMPANY_NAME}-EnterpriseClaw".
def --env "containers project" [] {
    $"($env.COMPANY_NAME)-EnterpriseClaw"
}

# Full ECR repo URI for an action: <registry-host>/<project>/<action-name>.
def --env "containers artifact url" [
    --action-name: string
    --region: string = ""
] {
    let repo_name = $"(containers project)/($action_name)"
    ecr repo-uri --repo-name=$repo_name --region=$region
}

def --env "containers init" [] {
    #1. Obtener información de podman
    let podman_machine_info = podman machine list --format json | from json

    #2. Si no hay ningún podman-machine
    if ($podman_machine_info | is-empty) {
        podman machine init
        podman machine start
    } else if ($podman_machine_info | get Running | where ($it == true) | is-empty) {
        #3. Si no hay ninguna máquina en ejecución
        podman machine start
    }
}

def --env "containers login" [
    --region: string = ""
] {
    let r = (if ($region | is-not-empty) { $region } else { $env.region })
    let login_host = (ecr registry-host --region=$r)
    ecr password --region=$r | podman login --username AWS --password-stdin $login_host
}

# Build a multi-arch (amd64+arm64) manifest for one action.
#   --context      build context directory (repo ROOT for the enterpriseclaw action; the action dir otherwise)
#   --dockerfile   path to the Dockerfile (relative to --context, or absolute)
def --env "containers build" [
    --tag: string
    --action-name: string
    --context: string
    --dockerfile: string
    --region: string = ""
] {
    let artifact = (containers artifact url --action-name=$action_name --region=$region)
    podman build --platform linux/amd64 -f $dockerfile --manifest $"($artifact):($tag)" -t $"($artifact):amd64" $context
    podman build --platform linux/arm64 -f $dockerfile --manifest $"($artifact):($tag)" -t $"($artifact):arm64" $context
}

def --env "containers push" [
    --tag: string
    --action-name: string
    --region: string = ""
] {
    let artifact = (containers artifact url --action-name=$action_name --region=$region)
    podman manifest push --all $"($artifact):($tag)" $"docker://($artifact):($tag)"
}
