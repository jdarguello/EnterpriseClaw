# EventSource + Sensor (the inbound half)

## EventSource ([slack-event-source.yaml](../../../gitops/config/argo-events/slack-event-source.yaml))

`kind: EventSource`, name `slack`, ns `argo-events`. Slack delivers over the **Events API (HTTP)**, not Socket Mode — it POSTs to the public Request URL.

Key fields:
- `spec.service.ports`: port/targetPort **12001**.
- `spec.slack.chat.webhook`: `endpoint: /slack`, `port: "12001"`, `method: POST`. The webhook key (`chat`) becomes the Sensor's `eventName`.
- `spec.slack.token` → `slack-secret` key `token` = the **Verification Token** (gotcha 1 — NOT the bot xoxb- token).
- `spec.slack.signingSecret` → `slack-secret` key `signingSecret` = the **Signing Secret** (validates `X-Slack-Signature` on every request, including the challenge).

The EventSource: answers Slack's `url_verification` challenge automatically, verifies the signature + verification token on every request, and publishes message events onto the NATS EventBus.

**url_verification quirk:** argo-events writes the challenge then `data==nil` → `SendSuccessResponse`, so the response body is `<challenge>success` (trailing `success`, plus a harmless `superfluous response.WriteHeader` log line). Slack's plain-text verification tolerates it (URL verifies green). A scoped EnvoyFilter Lua response-trim on istio-ingress is a *ready fallback*, not deployed.

## The dispatched payload schema (the expensive lesson)

For an `event_callback`, the Slack source does `data = json.Marshal(&eventsAPIEvent.InnerEvent)` and dispatches that **directly** as the event Data. **There is NO `body`/`header` wrapper** — unlike the github webhook source (which wraps, hence its `body.repository…`; the github sensor is [sensor.yaml](../../../gitops/config/argo-events/sensor.yaml)). Sensor filters + trigger params are resolved with **gjson** against this Data.

Verified exact shape (by replaying a signed synthetic app_mention; the source re-marshals through slack-go, so synthetic == production):

```json
{
  "type": "app_mention",
  "Data": {
    "type": "app_mention",
    "user":      "U…",
    "text":      "<@U0BOT> …",
    "ts":        "1719…",
    "thread_ts": "",
    "channel":   "C…",
    "event_ts":  "1719…"
  }
}
```

Note the **capital-D `Data`** — slack-go `EventsAPIInnerEvent.Data` has no json tag, so Go serializes the field name verbatim. gjson paths:

| need | gjson dataKey |
|---|---|
| event type (for the filter) | `type` |
| message text | `Data.text` |
| who mentioned the bot | `Data.user` |
| channel | `Data.channel` |
| message ts | `Data.ts` |
| thread root (empty for a top-level mention) | `Data.thread_ts` |
| the whole payload | `@this` |

`dataKey: body` → `key body does not exist in the event payload` → trigger fails `unable to resolve '<dep>' parameter value`. (Argo Events param resolution: empty `dataKey` does NOT mean "whole body" — use `@this`.)

## Sensor ([slack-sensor.yaml](../../../gitops/config/argo-events/slack-sensor.yaml))

`kind: Sensor`, name `slack-mention`, ns `argo-events`, `serviceAccountName: default` (bound to ClusterRole `admin` via [clusterrolebinding.yaml](../../../gitops/config/argo-events/clusterrolebinding.yaml), so it may create Workflows in ns `argo`).

- **dependency** `slack-event`: `eventSourceName: slack`, `eventName: chat`, with a data **filter** `path: type` `value: [app_mention]` (defense-in-depth — pins the trigger to mentions even if more bot events are subscribed later).
- **trigger** creates a Workflow in ns `argo` (`generateName: slack-mention-`, `serviceAccountName: pipe-storage`, `ttlStrategy.secondsAfterCompletion: 600`), mapping the event into named params:

```yaml
parameters:
  - { src: { dependencyName: slack-event, dataKey: Data.text },    dest: spec.arguments.parameters.0.value }  # text
  - { src: { dependencyName: slack-event, dataKey: Data.user },    dest: spec.arguments.parameters.1.value }  # user
  - { src: { dependencyName: slack-event, dataKey: Data.channel }, dest: spec.arguments.parameters.2.value }  # channel
  - { src: { dependencyName: slack-event, dataKey: Data.ts },      dest: spec.arguments.parameters.3.value }  # ts
  - { src: { dependencyName: slack-event, dataKey: Data.thread_ts, value: "" }, dest: spec.arguments.parameters.4.value }  # thread_ts (default!)
```

**`thread_ts` carries `value: ""`** as a default — it is `""` for a top-level mention, and without the default an empty/absent key can fail param resolution and wedge the whole trigger.

These five params (`text`/`user`/`channel`/`ts`/`thread_ts`) are exactly what the downstream §2.2 steps consume: `user` → Step 0 identity-resolve (`X-Slack-User-Id`), `text` → the agent (A2A `message/send`), `channel`/`ts`/`thread_ts` → where + which thread to reply into. See `reply-path.md` for the Workflow body.
