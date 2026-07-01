# a2a/main.nu — A2A (Agent2Agent) JSON-RPC client for the enterpriseclaw CLI.
#
# The Argo Workflow's "call the agent" step. Speaks the A2A protocol 0.3 `message/send` JSON-RPC
# method against a kagent Declarative agent's per-pod A2A server (ClusterIP `<agent>.<ns>:8080`,
# JSON-RPC base URL). A2A is a PROTOCOL (with SDKs), NOT a GitHub Marketplace action — do not hunt
# for one. Envelope shape verified against `.claude/skills/kagent-trio/reference/crds.md`
# ("Reaching a Declarative agent over A2A") and the A2A 0.3 spec.
#
# Container-safe: uses ONLY nushell built-in `http` (no curl/kubectl/aws/tofu). Split into PURE
# helpers (unit-tested, no IO, no $env) + a thin IO command. Def bodies are not executed at source
# time, so this module loads fine inside the slim nushell-only enterpriseclaw image.
#
# Sync vs async (decided): kagent's Declarative-agent `message/send` returns a **completed Task
# synchronously** (crds.md, verified 2026-06-25: `result.artifacts[]` carries the final text in the
# same response). So the happy path is a SINGLE call. Per the A2A 0.3 spec `status.state` can also be
# `working`/`submitted`/`input-required`; for robustness `main a2a call` does a BOUNDED `tasks/get`
# poll ONLY when the first reply is a Task in a non-terminal state. The pure parser handles Task
# (artifacts / history) AND the `kind:"message"` quick-response shape AND JSON-RPC error objects.

# --- PURE: build the JSON-RPC `message/send` request record (no IO, no $env) -----------------------
# `message-id` is injected (caller passes `random uuid`) so the builder stays deterministic/testable.
def "a2a build-request" [
    --message: string           # the user text to send to the agent
    --message-id: string        # a fresh UUID (caller supplies via `random uuid`)
    --id: string = "1"          # JSON-RPC request id
] {
    {
        jsonrpc: "2.0",
        id: $id,
        method: "message/send",
        params: {
            message: {
                role: "user",
                kind: "message",
                parts: [ { kind: "text", text: $message } ],
                messageId: $message_id
            }
        }
    }
}

# --- PURE: build a `tasks/get` request record (bounded-poll follow-up) -----------------------------
def "a2a build-tasks-get" [
    --task-id: string
    --id: string = "1"
] {
    { jsonrpc: "2.0", id: $id, method: "tasks/get", params: { id: $task_id } }
}

# --- PURE: join the `text` parts of a parts[] array into one string --------------------------------
def "a2a text-of-parts" [parts: any] {
    let d = ($parts | describe)
    # A list of records describes as `table<...>`; a heterogeneous/empty list as `list<...>`.
    if (($d | str starts-with "list") or ($d | str starts-with "table")) {
        $parts
        | where {|p| ($p | get -i kind | default "") == "text" }
        | each {|p| ($p | get -i text | default "") }
        | str join "\n"
        | str trim
    } else {
        ""
    }
}

# --- PURE: extract the agent's final text from a parsed A2A reply record ---------------------------
# Returns `{ok: true, text: <string>}` on success, or `{ok: false, error: <msg>, status: <code>}`.
# Also surfaces `{ok: false, needs_poll: true, task_id, status}` when the reply is a non-terminal
# Task (the IO command turns that into a `tasks/get` poll). Handles:
#   • JSON-RPC error object            → error
#   • kind:"message" quick response    → result.parts[] text
#   • kind:"task" completed            → result.artifacts[].parts[] text, else last agent history turn
#   • kind:"task" non-terminal         → needs_poll
def "a2a parse-response" [reply: any] {
    # 1. JSON-RPC transport/protocol error object
    let err = ($reply | get -i error)
    if ($err != null) {
        let code = ($err | get -i code | default (-32000))
        let msg = ($err | get -i message | default "A2A JSON-RPC error")
        return { ok: false, error: $msg, status: $code }
    }

    let result = ($reply | get -i result)
    if ($result == null) {
        return { ok: false, error: "A2A reply had no result", status: -32001 }
    }

    let kind = ($result | get -i kind | default "")

    # 2. Quick-response Message (no task created)
    if ($kind == "message") {
        let t = (a2a text-of-parts ($result | get -i parts | default []))
        if ($t | is-empty) {
            return { ok: false, error: "A2A message reply had no text parts", status: -32002 }
        }
        return { ok: true, text: $t }
    }

    # 3. Task
    let state = ($result | get -i status | default {} | get -i state | default "")

    # 3a. Non-terminal → caller must poll tasks/get
    if ($state in ["working" "submitted"]) {
        let tid = ($result | get -i id | default "")
        return { ok: false, needs_poll: true, task_id: $tid, status: $state }
    }

    # 3b. input-required with no artifacts is a legit agent turn (a clarifying question in status.message)
    #     — treat like completed: pull whatever text is available.

    # Prefer artifacts
    let artifacts = ($result | get -i artifacts | default [])
    let art_text = (
        $artifacts
        | each {|a| a2a text-of-parts ($a | get -i parts | default []) }
        | where {|t| ($t | is-not-empty) }
        | str join "\n"
        | str trim
    )
    if ($art_text | is-not-empty) {
        return { ok: true, text: $art_text }
    }

    # Fall back to the last agent turn in history
    let history = ($result | get -i history | default [])
    let agent_turns = (
        $history
        | where {|h| (($h | get -i role | default "") in ["agent" "assistant"]) }
    )
    if (($agent_turns | length) > 0) {
        let last = ($agent_turns | last)
        let t = (a2a text-of-parts ($last | get -i parts | default []))
        if ($t | is-not-empty) {
            return { ok: true, text: $t }
        }
    }

    # Fall back to the status.message parts (e.g. an input-required clarifying question)
    let status_msg_parts = ($result | get -i status | default {} | get -i message | default {} | get -i parts | default [])
    let sm_text = (a2a text-of-parts $status_msg_parts)
    if ($sm_text | is-not-empty) {
        return { ok: true, text: $sm_text }
    }

    { ok: false, error: $"A2A task returned no extractable text \(state: ($state))", status: -32003 }
}

# --- PURE: normalize an http error into the failure output shape ----------------------------------
def "a2a http-error" [status: int, body: any] {
    mut msg = $"A2A HTTP ($status)"
    let b = (try { $body | get -i error | get -i message } catch { null })
    if ($b != null) { $msg = $b }
    { ok: false, error: $msg, status: $status }
}

# --- IO: emit the JSON result to --out (if given) and stdout; exit non-zero on failure -------------
def "a2a emit" [result: record, out: string] {
    let payload = (
        if ($result.ok) {
            { text: $result.text }
        } else {
            { error: ($result | get -i error | default "unknown"), status: ($result | get -i status | default (-1)) }
        }
    )
    let json = ($payload | to json)
    if ($out | is-not-empty) {
        $json | save -f $out
    }
    print $json
    if (not $result.ok) {
        exit 1
    }
    $payload
}

# --- IO: perform the A2A `message/send` call --------------------------------------------------------
# Exits NON-ZERO on HTTP 401/403/5xx, a JSON-RPC error, or an empty/unparseable reply (so the Argo
# DAG can branch on step success). Writes {"text":...} / {"error":...,"status":...} to --out + stdout.
def "main a2a call" [
    --url: string                   # agent JSON-RPC base URL (e.g. http://general-classifier.kagent:8080)
    --message: string               # user text to send
    --token: string = ""            # optional bearer (platform-agent-via-agentgateway hop only)
    --out: string = ""              # optional path to write the JSON result
    --max-poll: int = 5             # bounded tasks/get attempts for a non-terminal Task
    --poll-interval: duration = 2sec
] {
    mut headers = { "Content-Type": "application/json" }
    if ($token | is-not-empty) {
        $headers = ($headers | insert Authorization $"Bearer ($token)")
    }

    let req = (a2a build-request --message=$message --message-id=(random uuid))

    # http post --full so we can read the status code; --allow-errors so 4xx/5xx don't throw.
    let resp = (
        try {
            http post --full --allow-errors --headers $headers --content-type "application/json" $url ($req | to json)
        } catch {|e|
            a2a emit { ok: false, error: $"A2A transport error: ($e.msg)", status: -1 } $out
            return
        }
    )

    let status = ($resp | get -i status | default 0)
    if ($status >= 400) {
        a2a emit (a2a http-error $status ($resp | get -i body)) $out
        return
    }

    let body = ($resp | get -i body)
    let reply = (
        if ($body | describe | str starts-with "record") { $body }
        else { try { $body | from json } catch { null } }
    )
    if ($reply == null) {
        a2a emit { ok: false, error: "A2A reply was empty/unparseable", status: -32004 } $out
        return
    }

    mut parsed = (a2a parse-response $reply)

    # Bounded tasks/get poll only if the first reply was a non-terminal Task.
    if ((not $parsed.ok) and ($parsed | get -i needs_poll | default false)) {
        let tid = ($parsed | get -i task_id | default "")
        mut attempt = 0
        while ($attempt < $max_poll) {
            sleep $poll_interval
            $attempt = $attempt + 1
            let get_req = (a2a build-tasks-get --task-id=$tid)
            let gresp = (
                try {
                    http post --full --allow-errors --headers $headers --content-type "application/json" $url ($get_req | to json)
                } catch {|e| null }
            )
            if ($gresp == null) { continue }
            let gstatus = ($gresp | get -i status | default 0)
            if ($gstatus >= 400) {
                $parsed = (a2a http-error $gstatus ($gresp | get -i body))
                break
            }
            let gbody = ($gresp | get -i body)
            let greply = (
                if ($gbody | describe | str starts-with "record") { $gbody }
                else { try { $gbody | from json } catch { null } }
            )
            if ($greply == null) { continue }
            let gp = (a2a parse-response $greply)
            if ($gp.ok) { $parsed = $gp; break }
            if (not ($gp | get -i needs_poll | default false)) { $parsed = $gp; break }
            # still working → loop
        }
        if ((not $parsed.ok) and ($parsed | get -i needs_poll | default false)) {
            $parsed = { ok: false, error: $"A2A task still non-terminal after ($max_poll) polls", status: -32005 }
        }
    }

    a2a emit $parsed $out
}
