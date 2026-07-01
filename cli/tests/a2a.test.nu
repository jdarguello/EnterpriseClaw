# a2a.test.nu — unit tests for the A2A JSON-RPC client's PURE helpers (cluster-free, no IO).
use std assert
source ../a2a/main.nu
source harness.nu

def "a2a-tests" [] {
    [
        # ---- build-request: correct JSON-RPC 0.3 envelope (kind, not type) ----
        { name: "build-request shapes a message/send envelope", run: {||
            let r = (a2a build-request --message="hello" --message-id="uuid-1")
            assert equal $r.jsonrpc "2.0"
            assert equal $r.method "message/send"
            assert equal $r.params.message.role "user"
            assert equal $r.params.message.kind "message"
            assert equal $r.params.message.messageId "uuid-1"
            assert equal ($r.params.message.parts | first | get kind) "text"
            assert equal ($r.params.message.parts | first | get text) "hello"
        }}

        # ---- build-tasks-get ----
        { name: "build-tasks-get shapes a tasks/get envelope", run: {||
            let r = (a2a build-tasks-get --task-id="t-99")
            assert equal $r.method "tasks/get"
            assert equal $r.params.id "t-99"
        }}

        # ---- parse: completed Task with artifacts text ----
        { name: "parse-response extracts artifacts text (Task)", run: {||
            let reply = { jsonrpc: "2.0", id: "1", result: {
                kind: "task", id: "t1",
                status: { state: "completed" },
                artifacts: [ { parts: [ { kind: "text", text: "PR opened" } { kind: "data", data: {} } ] } ],
                history: []
            }}
            let out = (a2a parse-response $reply)
            assert equal $out.ok true
            assert equal $out.text "PR opened"
        }}

        # ---- parse: multiple artifacts + multiple text parts join ----
        { name: "parse-response joins multiple text parts", run: {||
            let reply = { result: {
                kind: "task", status: { state: "completed" },
                artifacts: [ { parts: [ { kind: "text", text: "line1" } { kind: "text", text: "line2" } ] } ]
            }}
            let out = (a2a parse-response $reply)
            assert equal $out.ok true
            assert equal $out.text "line1\nline2"
        }}

        # ---- parse: history-only fallback (no artifacts) ----
        { name: "parse-response falls back to last agent history turn", run: {||
            let reply = { result: {
                kind: "task", status: { state: "completed" },
                artifacts: [],
                history: [
                    { role: "user", parts: [ { kind: "text", text: "hi" } ] }
                    { role: "agent", parts: [ { kind: "text", text: "first agent turn" } ] }
                    { role: "agent", parts: [ { kind: "text", text: "final agent turn" } ] }
                ]
            }}
            let out = (a2a parse-response $reply)
            assert equal $out.ok true
            assert equal $out.text "final agent turn"
        }}

        # ---- parse: quick-response Message (kind:message) ----
        { name: "parse-response handles kind:message quick reply", run: {||
            let reply = { result: {
                kind: "message", messageId: "m1",
                parts: [ { kind: "text", text: "quick answer" } ]
            }}
            let out = (a2a parse-response $reply)
            assert equal $out.ok true
            assert equal $out.text "quick answer"
        }}

        # ---- parse: JSON-RPC error object ----
        { name: "parse-response surfaces a JSON-RPC error object", run: {||
            let reply = { jsonrpc: "2.0", id: "1", error: { code: -32601, message: "Method not found" } }
            let out = (a2a parse-response $reply)
            assert equal $out.ok false
            assert equal $out.error "Method not found"
            assert equal $out.status (-32601)
        }}

        # ---- parse: non-terminal Task → needs_poll ----
        { name: "parse-response flags a working Task for polling", run: {||
            let reply = { result: { kind: "task", id: "t-poll", status: { state: "working" } } }
            let out = (a2a parse-response $reply)
            assert equal $out.ok false
            assert equal ($out | get -i needs_poll | default false) true
            assert equal $out.task_id "t-poll"
        }}

        # ---- parse: input-required clarifying question in status.message ----
        { name: "parse-response reads status.message on input-required", run: {||
            let reply = { result: {
                kind: "task", status: { state: "input-required",
                    message: { role: "agent", parts: [ { kind: "text", text: "which region?" } ] } },
                artifacts: [], history: []
            }}
            let out = (a2a parse-response $reply)
            assert equal $out.ok true
            assert equal $out.text "which region?"
        }}

        # ---- parse: missing result ----
        { name: "parse-response errors when result is absent", run: {||
            let reply = { jsonrpc: "2.0", id: "1" }
            let out = (a2a parse-response $reply)
            assert equal $out.ok false
        }}

        # ---- parse: completed Task with no extractable text ----
        { name: "parse-response errors on empty completed task", run: {||
            let reply = { result: { kind: "task", status: { state: "completed" }, artifacts: [], history: [] } }
            let out = (a2a parse-response $reply)
            assert equal $out.ok false
        }}

        # ---- text-of-parts: ignores non-text parts, handles non-list ----
        { name: "text-of-parts filters non-text and non-list", run: {||
            assert equal (a2a text-of-parts [ { kind: "file" } { kind: "text", text: "keep" } ]) "keep"
            assert equal (a2a text-of-parts "not-a-list") ""
        }}

        # ---- http-error shaping ----
        { name: "http-error uses body message when present", run: {||
            let e = (a2a http-error 403 { error: { message: "forbidden" } })
            assert equal $e.ok false
            assert equal $e.status 403
            assert equal $e.error "forbidden"
        }}
        { name: "http-error falls back to a generic message", run: {||
            let e = (a2a http-error 500 { garbage: true })
            assert equal $e.error "A2A HTTP 500"
            assert equal $e.status 500
        }}
    ]
}
