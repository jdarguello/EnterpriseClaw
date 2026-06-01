def --env "github clone" [] {
    gh repo clone $"($env.ORG_NAME)/($env.CONFIG_REPO)" ./gitops-config
}

def --env "github pr" [
    --branch-name:      string
] {
    
}