# containers/main.nu — build & publish the actions/ images to the private ECR.
#
# Fixed 2026-07-01: the module previously `source ../aws/ecr.nu` against a non-existent dir and relied
# on `$env.AWS_ROLE`/`$env.environment`/an `opentofu output`. Now it derives everything from `$env`
# (region, COMPANY_NAME) + `aws sts` (see aws/ecr.nu + podman.nu) and builds every dir under actions/.
#
# ECR repo naming (frozen contract): `${project}/<action-name>` where project =
# "${COMPANY_NAME}-EnterpriseClaw" (matches cli/infra/vars.nu). The image-registries tofu module
# AUTO-CREATES these repos by globbing actions/*/README.md, so `main containers new-image` only
# builds+pushes into pre-existing repos — idempotent, safe to re-run.
#
# BUILD-CONTEXT RULE (settled): most actions build from their OWN action dir (their Dockerfiles curl
# the upstream action source and have no local COPY). The `enterpriseclaw` action's Dockerfile COPYs
# `cli/`, so it needs build context = repo ROOT. The rule is data-driven, not name-hardcoded: an action
# is built from repo ROOT iff its Dockerfile contains a `COPY`/`ADD` of a repo-root path (heuristic:
# any `COPY`/`ADD` referencing `cli/`); otherwise from the action dir. `-f <dockerfile>` is always
# passed explicitly so the context choice is independent of where the Dockerfile lives.

source podman.nu
source ../aws/ecr.nu

# Compile & publish EVERY action under --path (default ../actions).
def --env "main containers new-image all" [
    --path: string = "../actions"      # path to the actions tree
    --cloud-provider: string = "aws"   # options: 'aws'
] {
    for item in (ls $path) {
        if ($item.type == "dir") {
            let action_name = ($item.name | path basename)
            main containers new-image --action-name=$action_name --path-base=$path --cloud-provider=$cloud_provider
        }
    }
}

# Compile & publish ONE action.
def --env "main containers new-image" [
    --action-name: string              # action directory name (e.g. checkout)
    --path-base: string = "../actions" # path to the actions tree
    --tag: string = ""                 # override; else resolved from tag.txt / the versioned subdir
    --cloud-provider: string = "aws"   # options: 'aws'
    --push = true                      # set false to build-only (local verification)
] {
    let action_dir = $"($path_base)/($action_name)"
    let resolved_tag = (if ($tag | is-not-empty) { $tag } else { containers get tag --path=$action_dir })
    let dockerfile = (containers dockerfile --action-dir=$action_dir --tag=$resolved_tag)
    let build_at_root = (containers needs-root-context --dockerfile=$dockerfile)

    # Build context + a Dockerfile path expressed RELATIVE to that context.
    let repo_root = ($path_base | path dirname)   # actions/ lives at repo root → parent = repo root
    let context = (if $build_at_root { $repo_root } else { $action_dir })
    let df_for_build = $dockerfile   # absolute-ish path from cwd works for both contexts with podman -f

    #1. podman machine up
    containers init

    #2. ECR login
    containers login

    #3. build (multi-arch manifest)
    containers build --tag=$resolved_tag --action-name=$action_name --context=$context --dockerfile=$df_for_build

    #4. push
    if $push {
        containers push --tag=$resolved_tag --action-name=$action_name
    }
}

# Resolve an action's tag: prefer <action>/tag.txt; else the single versioned subdirectory name.
def "containers get tag" [
    --path: string
] {
    let tag_file = $"($path)/tag.txt"
    if ($tag_file | path exists) {
        return (open $tag_file | str trim)
    }
    # Fall back to the single versioned subdir (e.g. checkout/5.0.0).
    let subdirs = (ls $path | where type == "dir" | get name | each {|n| $n | path basename })
    if (($subdirs | length) == 1) {
        return ($subdirs | first)
    }
    error make { msg: $"cannot resolve tag for ($path): no tag.txt and (($subdirs | length)) versioned subdirs (expected exactly 1)" }
}

# The Dockerfile path for an action at a given tag: <action-dir>/<tag>/Dockerfile.
def "containers dockerfile" [
    --action-dir: string
    --tag: string
] {
    let df = $"($action_dir)/($tag)/Dockerfile"
    if (not ($df | path exists)) {
        error make { msg: $"Dockerfile not found: ($df)" }
    }
    $df
}

# Heuristic: does this Dockerfile need repo-ROOT build context? True iff it COPY/ADDs a repo-root
# path (we key on a `cli/` reference, which the enterpriseclaw image uses). Actions that only curl
# their upstream source have no such COPY and build fine from their own dir.
def "containers needs-root-context" [
    --dockerfile: string
] {
    let content = (open --raw $dockerfile | decode utf-8)
    ($content
        | lines
        | any {|l|
            let t = ($l | str trim)
            (($t | str starts-with "COPY") or ($t | str starts-with "ADD")) and ($t | str contains "cli/")
        })
}
