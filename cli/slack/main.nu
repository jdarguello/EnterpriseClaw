# slack/main.nu — Slack integration commands for the enterpriseclaw CLI.
#
# Canonical home for the Slack reply logic (the "AI proposes / pipeline disposes" loop posts its
# answer back into the originating Slack thread). Split into a PURE payload builder (unit-tested,
# cluster-free) and a thin IO command that performs the chat.postMessage call.
#
# NOTE (2026-07-01): the `enterpriseclaw` container image now EXISTS
# (actions/enterpriseclaw/v0.1.0/Dockerfile) and the Slack Workflow uses it, so these commands run
# in-cluster from that image (an Argo Workflow step invokes e.g. `enterpriseclaw slack reply ...` /
# `enterpriseclaw slack thread ...` directly). They remain usable locally as well against a channel
# the bot is a member of.

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

# Render a Slack conversations.replies `messages` list into a plain-text conversation transcript
# (PURE — no IO, no $env). Input: the messages list on stdin (a list of records, IN thread order).
# Output: a string of `"<Role>: <text>"` lines joined by newline.
#
# Why: the Slack->agent pipeline is stateless (one Argo Workflow run per inbound message), so a
# follow-up reply is unclassifiable in isolation. We rebuild the whole thread each turn and feed the
# transcript to the classifier/reader agent.
#
# Role detection does NOT depend on --bot-user-id: a message is "Assistant" if it carries a bot
# marker (non-empty `bot_id`, `subtype == "bot_message"`, or a non-empty `app_id`); otherwise "User".
# --bot-user-id is used ONLY to strip the bot's own self-mention (kept generic: ALL user-mention
# tokens `<@U...>`/`<@W...>` are stripped regardless).
def "slack thread-transcript" [
    --bot-user-id: string = ""      # bot's own Slack user id (only used to strip its self-mention)
] {
    let messages = $in
    # System/membership events (joins, leaves, topic/purpose changes, etc.) carry a subtype and are
    # noise for the agent — drop them up front. (Their residual text after mention-stripping, e.g.
    # "has joined the channel", is non-empty, so the empty-text filter alone would not catch them.)
    let skip_subtypes = [
        "channel_join" "channel_leave" "group_join" "group_leave"
        "channel_topic" "channel_purpose" "channel_name" "channel_archive" "channel_unarchive"
    ]
    $messages
    | where (($it | get -i subtype | default "") not-in $skip_subtypes)
    | each {|m|
        let is_bot = (
            (($m | get -i bot_id | default "" | is-not-empty))
            or (($m | get -i subtype | default "") == "bot_message")
            or (($m | get -i app_id | default "" | is-not-empty))
        )
        let role = (if $is_bot { "Assistant" } else { "User" })
        # Strip all Slack user-mention tokens (<@U...> / <@W...>), then trim leftover whitespace.
        let text = (
            ($m | get -i text | default "")
            | str replace -a -r '<@[A-Z0-9]+>' ''
            | str trim
        )
        { role: $role, text: $text }
    }
    | where ($it.text | is-not-empty)      # drop join/leave events, textless files, etc.
    | each {|r| $"($r.role): ($r.text)" }
    | str join "\n"
}

# Fetch a Slack thread's history via conversations.replies and render it as a transcript. Bot token
# (a `xoxb-` token with the read scopes) comes from --token or, by default, $env.SLACK_BOT_TOKEN.
# Raises on Slack's logical failures (HTTP 200 with {ok:false,error:...}) so the caller can try/catch
# and fall back to the single inbound message.
#
# Thread root = --thread-ts if non-empty, else --ts (a top-level mention has an empty thread_ts, so
# we thread under the message's own ts).
def "main slack thread" [
    --channel: string           # Slack channel ID (e.g. C0123ABC)  (required)
    --ts: string                # the originating message ts          (required)
    --thread-ts: string = ""    # thread root ts; may be empty (default "")
    --token: string = ""        # bot token; defaults to $env.SLACK_BOT_TOKEN
    --out: string = ""          # if set, WRITE transcript here and print nothing to stdout
    --bot-user-id: string = ""  # bot's own Slack user id (only used to strip its self-mention)
] {
    let bot_token = (if ($token | is-not-empty) { $token } else { $env.SLACK_BOT_TOKEN })
    let root = (if ($thread_ts | is-not-empty) { $thread_ts } else { $ts })
    let qs = ([
        $"channel=($channel | url encode)"
        $"ts=($root | url encode)"
        "limit=100"
    ] | str join "&")
    let url = $"https://slack.com/api/conversations.replies?($qs)"
    let resp = (http get --headers { Authorization: $"Bearer ($bot_token)" } $url)
    if (not ($resp | get -i ok | default false)) {
        error make { msg: $"Slack conversations.replies failed: ($resp | get -i error | default 'unknown')" }
    }
    let transcript = (
        $resp | get -i messages | default []
        | slack thread-transcript --bot-user-id=$bot_user_id
    )
    if ($out | is-not-empty) {
        $transcript | save --force $out
        print -e $"wrote transcript to ($out)"
    } else {
        $transcript
    }
}
