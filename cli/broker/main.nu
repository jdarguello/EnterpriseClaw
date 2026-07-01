# broker/main.nu — Session-Broker HTTP client for the enterpriseclaw CLI.
#
# The Argo Workflow's identity steps (§2.2 Step 0 + the no-token login-wall). The broker binds a
# `slack_user_id` → a real Keycloak identity and caches the user's tokens. Lives in a SEPARATE repo
# (github.com/jdarguello/Session-Broker); EnterpriseClaw is the CONSUMER. Endpoints (per the
# session-broker skill):
#   POST /identity/resolve   header X-Slack-User-Id   → cached user identity/token (Step 0)
#   POST /auth/login/start   body {slack_user_id}     → a Keycloak /authorize URL (login-wall)
#
# Container-safe: ONLY nushell built-in `http` (no curl/kubectl/aws/tofu). Split into PURE
# response→output mappers (unit-tested) + thin IO commands.
#
# CONFIRMED 2026-07-01 against the live sandbox broker (FastAPI). Real shapes:
#   /identity/resolve → discriminated union on `type`, keyed off the X-Slack-User-Id HEADER:
#       {"type":"unauthenticated","slack_user_id":"<id>"}                              (no token cached)
#       {"type":"authenticated","access_token":"<jwt>","sub":..,"email":..,"roles":[..],"slack_user_id":..}
#     → has_token ≡ type=="authenticated"; the JWT is in `access_token` (NOT `token`).
#   /auth/login/start → requires `slack_user_id` as a JSON BODY field (NOT a header); 422 if missing;
#       response {"authorize_url":"<keycloak /authorize>","state":"<nonce>"} → URL is `authorize_url`.
# The response→output mapping stays isolated in the two pure functions below.

# --- PURE: map an /identity/resolve reply record → {has_token, token} ------------------------------
# CONFIRMED live: broker returns a discriminated union on `type` ("authenticated"|"unauthenticated");
# the JWT (when present) is in `access_token`. Kept defensive to alternate field names.
# has_token:false is the legitimate "user must log in" branch — NOT an error.
def "broker parse-resolve" [reply: any] {
    if (($reply | describe | str starts-with "record") == false) {
        return { has_token: false, token: "" }
    }
    # token: first non-empty known field (access_token is the CONFIRMED live field; others defensive).
    let token = (
        [ (($reply | get -i access_token))
          (($reply | get -i token))
          (($reply | get -i jwt))
          (($reply | get -i user_token)) ]
        | where {|v| ($v != null) and (($v | describe) == "string") and ($v | is-not-empty) }
        | append ""
        | first
    )
    # has_token: the CONFIRMED discriminator is the string `type`; fall back to an explicit boolean
    # field, then to token-presence, for any other broker shape.
    let rtype = ($reply | get -i type | default "")
    let explicit = (
        [ (($reply | get -i has_token))
          (($reply | get -i authenticated))
          (($reply | get -i resolved)) ]
        | where {|v| ($v != null) and (($v | describe) == "bool") }
        | append null
        | first
    )
    let has = (
        if ($rtype == "authenticated") { true
        } else if ($rtype == "unauthenticated") { false
        } else if ($explicit != null) { $explicit
        } else { ($token | is-not-empty) }
    )
    { has_token: $has, token: $token }
}

# --- PURE: map an /auth/login/start reply record → {login_url} -------------------------------------
# CONFIRMED live: broker returns {authorize_url: "<keycloak /authorize>", state: "<nonce>"}.
# Kept defensive (also accepts login_url|authorization_url|url|redirect_url).
# Returns {ok:false} when no URL field is present so the IO command can fail cleanly.
def "broker parse-login" [reply: any] {
    if (($reply | describe | str starts-with "record") == false) {
        return { ok: false, login_url: "" }
    }
    let url = (
        [ (($reply | get -i authorize_url))
          (($reply | get -i login_url))
          (($reply | get -i authorization_url))
          (($reply | get -i url))
          (($reply | get -i redirect_url)) ]
        | where {|v| ($v != null) and (($v | describe) == "string") and ($v | is-not-empty) }
        | append ""
        | first
    )
    if ($url | is-empty) {
        return { ok: false, login_url: "" }
    }
    { ok: true, login_url: $url }
}

# --- IO helper: emit JSON to --out + stdout, optionally exit non-zero ------------------------------
def "broker emit" [payload: record, out: string, fail: bool] {
    let json = ($payload | to json)
    if ($out | is-not-empty) { $json | save -f $out }
    print $json
    if $fail { exit 1 }
    $payload
}

# --- IO helper: POST to a broker endpoint carrying X-Slack-User-Id ---------------------------------
# Returns {status: int, body: any} (full response). `body` is the JSON body (default {} — used by
# /identity/resolve, which reads only the header; /auth/login/start passes {slack_user_id}).
# --allow-errors so 4xx/5xx don't throw (we branch on status).
def "broker post" [base: string, path: string, slack_user_id: string, body: record = {}] {
    let url = $"($base | str trim -r -c '/')($path)"
    let headers = { "X-Slack-User-Id": $slack_user_id }
    http post --full --allow-errors --headers $headers --content-type "application/json" $url ($body | to json)
}

# --- IO: /identity/resolve (Step 0) ---------------------------------------------------------------
# Success → {has_token, token}. A 404 / 200-with-has_token:false / "no token" is NOT an error — it is
# the legitimate "user must log in" branch: returns has_token:false and exits ZERO (the DAG branches
# on the has_token VALUE). Only true transport / 5xx errors exit non-zero.
def "main broker resolve" [
    --url: string                   # broker base (e.g. http://session-broker.session-broker.svc.cluster.local)
    --slack-user-id: string         # Slack user id (U…)
    --out: string = ""              # optional path to write the JSON result
] {
    let resp = (
        try { broker post $url "/identity/resolve" $slack_user_id }
        catch {|e| { status: -1, body: { error: $e.msg } } }
    )
    let status = ($resp | get -i status | default (-1))

    # Transport / server error → fail the step.
    if (($status < 0) or ($status >= 500)) {
        let msg = (try { $resp.body | get -i error } catch { null } | default $"broker /identity/resolve HTTP ($status)")
        broker emit { has_token: false, token: "", error: $msg, status: $status } $out true
        return
    }

    # 404 (no cached identity) → legit login-required branch, exit zero.
    if ($status == 404) {
        broker emit { has_token: false, token: "" } $out false
        return
    }

    let body = ($resp | get -i body)
    let reply = (
        if ($body | describe | str starts-with "record") { $body }
        else { try { $body | from json } catch { null } }
    )
    let mapped = (broker parse-resolve $reply)
    broker emit { has_token: $mapped.has_token, token: $mapped.token } $out false
}

# --- IO: /auth/login/start (the no-token login-wall) ----------------------------------------------
# Success → {login_url}. Exits non-zero on 401/403/5xx or a missing URL field.
def "main broker login-start" [
    --url: string                   # broker base
    --slack-user-id: string         # Slack user id (U…)
    --out: string = ""              # optional path to write the JSON result
] {
    let resp = (
        try { broker post $url "/auth/login/start" $slack_user_id {slack_user_id: $slack_user_id} }
        catch {|e| { status: -1, body: { error: $e.msg } } }
    )
    let status = ($resp | get -i status | default (-1))

    if (($status < 0) or ($status == 401) or ($status == 403) or ($status >= 500)) {
        let msg = (try { $resp.body | get -i error } catch { null } | default $"broker /auth/login/start HTTP ($status)")
        broker emit { error: $msg, status: $status } $out true
        return
    }

    let body = ($resp | get -i body)
    let reply = (
        if ($body | describe | str starts-with "record") { $body }
        else { try { $body | from json } catch { null } }
    )
    let mapped = (broker parse-login $reply)
    if (not $mapped.ok) {
        broker emit { error: "broker /auth/login/start returned no login URL", status: $status } $out true
        return
    }
    broker emit { login_url: $mapped.login_url } $out false
}
