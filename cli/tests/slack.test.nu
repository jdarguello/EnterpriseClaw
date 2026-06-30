# slack.test.nu — unit tests for the Slack chat.postMessage payload builder (pure, cluster-free).
use std assert
source ../slack/main.nu
source harness.nu

def "slack-tests" [] {
    [
        # ---- top-level mention: thread under the message's own ts ----
        { name: "top-level mention threads under ts", run: {||
            let b = (slack reply-payload --channel="C1" --text="hi" --ts="123.45" --thread-ts="")
            assert equal $b.channel "C1"
            assert equal $b.text "hi"
            assert equal $b.thread_ts "123.45"
        }}

        # ---- in-thread mention: thread under the existing thread root ----
        { name: "in-thread mention threads under thread_ts", run: {||
            let b = (slack reply-payload --channel="C2" --text="yo" --ts="999.00" --thread-ts="555.00")
            assert equal $b.thread_ts "555.00"
        }}

        # ---- no ts and no thread_ts: channel-level post (no thread_ts key) ----
        { name: "no ts/thread_ts omits thread_ts entirely", run: {||
            let b = (slack reply-payload --channel="C3" --text="plain")
            assert equal ($b | columns | any {|c| $c == "thread_ts" }) false
            assert equal $b.channel "C3"
            assert equal $b.text "plain"
        }}

        # ---- channel + text pass through verbatim (incl. special chars) ----
        { name: "channel and text pass through unchanged", run: {||
            let b = (slack reply-payload --channel="C0DEMO" --text="deploy \"payments\" <svc>" --ts="1.2")
            assert equal $b.channel "C0DEMO"
            assert equal $b.text "deploy \"payments\" <svc>"
        }}
    ]
}
