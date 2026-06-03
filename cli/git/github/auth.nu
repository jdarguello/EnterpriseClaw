#Authenticates to GitHub using PAT
def --env "github auth" [] {
    #1. Token treatment
    rm ($nu.temp-dir + "/token.txt") --force
    let old_token = $env.GH_TOKEN
    ($env.GH_TOKEN | str trim) | save ($nu.temp-dir + "/token.txt")
    $env.GH_TOKEN = ""

    #2. Auth operation
    open ($nu.temp-dir + "/token.txt")
        | str trim
        | gh auth login --with-token

    #3. Token saving
    $env.GH_TOKEN = $old_token
    rm ($nu.temp-dir + "/token.txt")
}
