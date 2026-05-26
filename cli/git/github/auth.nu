#Authenticates to GitHub using PAT
def --env "github auth" [] {
    #1. Token treatment
    rm tmp/token.txt --force
    let old_token = $env.GH_TOKEN
    ($env.GH_TOKEN | str trim) | save tmp/token.txt
    $env.GITHUB_TOGH_TOKENKEN = ""

    #2. Auth operation
    open tmp/token.txt
        | str trim
        | gh auth login --with-token

    #3. Token saving
    $env.GH_TOKEN = $old_token
    rm tmp/token.txt
}
