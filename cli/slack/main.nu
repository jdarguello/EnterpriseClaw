# slack/main.nu — Slack integration commands for the enterpriseclaw CLI.
#
# Canonical home for the Slack reply logic (the "AI proposes / pipeline disposes" loop posts its
# answer back into the originating Slack thread). Split into a PURE payload builder (unit-tested,
# cluster-free) and a thin IO command that performs the chat.postMessage call.
#
# NOTE (2026-06-30): there is no `enterpriseclaw` container image yet, so an Argo Workflow step
# cannot invoke this command in-cluster. Until that image exists, the workflow's reply step runs an
# equivalent inline chat.postMessage (see gitops/config/argo-events/slack-sensor.yaml). This command
# is the convention-correct home for the logic and is usable locally (`enterpriseclaw main slack
# reply ...`) against a channel the bot is a member of.

# Build the Slack chat.postMessage request body (PURE — no IO, no $env).
#
# Threading rule: reply in-thread under the originating mention. If the mention itself was already
# inside a thread, `thread_ts` is that thread's root; for a top-level mention `thread_ts` is empty,
# so we thread under the message's own `ts`. If both are empty we omit thread_ts (channel-level post).
def "slack reply-payload" [
    --channel: string           # Slack channel ID (e.g. C0123ABC)
    --text: string              # message text
    --ts: string = ""           # the originating message ts
    --thread-ts: string = ""    # the originating thread root, if the mention was in a thread
] {
    let thread_root = (if ($thread_ts | is-not-empty) { $thread_ts } else { $ts })
    mut body = { channel: $channel, text: $text }
    if ($thread_root | is-not-empty) {
        $body = ($body | insert thread_ts $thread_root)
    }
    $body
}

# Post a reply to Slack via chat.postMessage. Bot token (a chat:write `xoxb-` token) comes from
# --token or, by default, $env.SLACK_BOT_TOKEN. Raises on Slack's logical failures (HTTP 200 with
# {ok:false,error:...}).
def "main slack reply" [
    --channel: string           # Slack channel ID
    --text: string              # message text
    --ts: string = ""           # originating message ts (threading)
    --thread-ts: string = ""    # originating thread root (threading)
    --token: string = ""        # bot token; defaults to $env.SLACK_BOT_TOKEN
] {
    let bot_token = (if ($token | is-not-empty) { $token } else { $env.SLACK_BOT_TOKEN })
    let body = (slack reply-payload --channel=$channel --text=$text --ts=$ts --thread-ts=$thread_ts)
    let resp = (http post
        --content-type "application/json"
        --headers { Authorization: $"Bearer ($bot_token)" }
        "https://slack.com/api/chat.postMessage"
        ($body | to json))
    if (not ($resp | get -i ok | default false)) {
        error make { msg: $"Slack chat.postMessage failed: ($resp | get -i error | default 'unknown')" }
    }
    print $"replied in ($channel)"
    $resp
}
