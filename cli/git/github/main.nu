def --env "github clone" [] {
    gh repo clone $"($env.ORG_NAME)/($env.CONFIG_REPO)" ./gitops-config
}

# Sets credentials for push-operation
def --env "github auth config" [] {
    git remote set-url origin $"https://($env.GIT_USER):($env.GH_TOKEN)@github.com/($env.ORG_NAME)/($env.CONFIG_REPO)"
}
