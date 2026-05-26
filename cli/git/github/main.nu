def --env "github clone" [] {
    gh repo clone $env.ORG_NAME/$env.CONFIG_REPO
}

def --env "github push" [] {
    
}