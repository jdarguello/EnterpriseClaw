source github/main.nu

# Git cloning
def "git-registry clone" [
    --git-provider: string      #Options: 'github'
] {
    if ($git_provider == "github") {
        github clone
    }
}

# Git push
def --env "git-registry push" [
    --git-provider:     string
    --commit-message:   string
] {
    #1. cd to repository
    let current_directory = pwd
    cd gitops-config/

    #2. Set git-credentials
    if ($git_provider == "github") {
        github auth config
    }

    #3. Push operation
    git-registry push operation --branch-name=$env.branch_name --commit-message=$commit_message
    
    #4. Return to original path
    cd $current_directory
}

def "git-registry push operation" [
    --branch-name:      string
    --commit-message:   string
] {
    #1. User definition
    git config user.name $env.GIT_USER
    git config user.email $env.GIT_USER_EMAIL

    #2. add commit
    git add .
    git commit -m $"($commit_message)"

    #3. push
    git push origin $branch_name
}