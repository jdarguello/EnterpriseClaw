source github/main.nu

# Git cloning
def "git clone" [
    --git-provider: string      #Options: 'github'
] {
    if ($git_provider == "github") {
        github clone
    }
}

# Git push
def "git push" [
    --git-provider: string      #Options: 'github'
] {
    #1. cd to repository
    let current_directory = pwd
    cd $"../infrastructure/($cloud_provider)"

    #2. Push operation
    if ($git_provider == "github") {
        github push
    }

    #3. Return to original path
    cd $current_directory
}