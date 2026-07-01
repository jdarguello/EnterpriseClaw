---
name: slack-integration
description: >-
  Authoritative reference for EnterpriseClaw's Slack inbound door — the Argo Events Slack
  EventSource (/slack), the `slack-mention` Sensor, and the per-message Argo Workflow that
  replies back into the thread. Use when extending, debugging, or testing the Slack ↔ Argo
  round-trip; when touching slack-creds / the slack-secret / slack-bot ExternalSecrets; when
  authoring the Sensor/Workflow or the `main slack reply` CLI command; or when building the
  agent middle (Step 0 → A2A → reply) on top of it. Covers the schema gotchas that waste hours
  and the synthetic-signed-event replay technique for testing without a human in Slack.
---

# Slack integration (the demo's front door)

The **inbound door of the §2.2 "Golden Path via chat" spine** ([CLAUDE.md](../../CLAUDE.md) §2.2/§3). A platform engineer `@mention`s the bot in Slack; one short-lived Argo Workflow runs per message, **reasons via the agent middle, and replies back into the thread**. **Built + LIVE on the AWS sandbox** — inbound door 2026-06-30, **agent middle wired 2026-07-01**.

```
Slack @mention
  → ALB (events.<domain>/slack)  → Istio ingress gateway → VirtualService (/slack path)
  → Argo Events Slack EventSource `slack` (ns argo-events, port 12001)  [validates sig + verification token]
  → NATS EventBus
  → Sensor `slack-mention` (ns argo-events)  [filter type==app_mention; extracts text/user/channel/ts/thread_ts]
  → Argo Workflow (ns argo, one run per message) — triage-first branching DAG:
      ├─ log      busybox echo of parsed fields — audit (always; independent)
      ├─ triage   rebuild thread transcript → A2A → general-classifier → {"category":"read-only"|"action"}
      ├─ read     when read-only → transcript → A2A → github-reader → reply     (workload rail, no JWT)
      ├─ resolve  when action   → broker POST /identity/resolve → {has_token, token}
      ├─ login    when !has_token → broker POST /auth/login/start → reply Keycloak login URL (the wall)
      └─ act      when  has_token → transcript → A2A via agentgateway (Bearer user JWT) → platform-agent → reply
      onExit: error-reply (post a generic apology if workflow.status != Succeeded)
```

The **agent middle IS wired** (as of 2026-07-01): Step 0 identity-resolve, the triage classifier, the read-only reader, the conditional login wall, and the JWT-bearing action call all run live. What remains net-new: the `act` branch's `platform-agent` goes fully green only once its `mcp-discovery-token` Secret is provisioned, and archive/artifacts + Crossplane. The single source of truth for the DAG is [slack-sensor.yaml](../../../gitops/config/argo-events/slack-sensor.yaml) (heavily commented); `reference/agent-middle.md` explains the branching + the multi-turn/classifier gotchas.

> **Dated knowledge.** Verified **2026-06-30** against **argo-events v1.9.10** (`quay.io/argoproj/argo-events`) on the AWS sandbox. Re-verify the Slack-source dispatch shape and the EventSource token semantics before trusting this on another argo-events release.

## Read this first — the gotchas that cost hours

1. **EventSource `token` is the Slack VERIFICATION TOKEN (legacy), NOT the bot `xoxb-` token.** argo-events `start.go` does `OptionVerifyToken(payload.token vs rc.token)`; a mismatch is HTTP **500 "invalid verification token"** and the url_verification challenge fails. Get it from Slack → Basic Information → App Credentials → Verification Token. The bot `xoxb-` token is a *separate* credential used only by the *reply* path. → `reference/eventsource-sensor.md`.
2. **The Slack source dispatches the inner event JSON DIRECTLY — there is NO `body`/`header` wrapper** (the github webhook source DOES wrap, hence its `body.repository…`; do not copy that). `dataKey: body` fails with `key body does not exist in the event payload` → trigger error `unable to resolve '<dep>' parameter value`. Verified dispatched shape: `{"type":"app_mention","Data":{type,user,text,ts,thread_ts,channel,event_ts}}` — note the **capital-D `Data`** (slack-go `EventsAPIInnerEvent.Data`, no json tag). gjson paths: filter on `type`; extract `Data.text`/`Data.user`/`Data.channel`/`Data.ts`/`Data.thread_ts`; `@this` = whole payload. → `reference/eventsource-sensor.md`.
3. **url_verification response is `<challenge>success`** — argo-events appends `success`. Slack's plain-text verification **tolerates** it (verified: URL goes green). An EnvoyFilter Lua response-trim is a *fallback*, NOT deployed. → `reference/eventsource-sensor.md`.
4. **The reply runs in ns `argo`, but the bot token's k8s Secret is in ns `argo-events`.** k8s Secrets are namespace-scoped, so the Workflow can't read it across namespaces — a **separate `slack-bot` ExternalSecret** materializes the same `slack-creds/bot_oauth_token` into ns `argo`. → `reference/reply-path.md`.
5. **No `enterpriseclaw` workflow image exists** (container build path is broken — CLAUDE.md §4), so the Workflow's reply step is **inline Python** (`json.dumps` = safe escaping), NOT the `main slack reply` CLI command. The CLI command is the convention-correct home for the logic and is usable locally; swap the workflow step to it once an image exists. → `reference/reply-path.md`.
6. **Argo CD owns these objects and self-heals.** A direct `kubectl apply` of an edited Sensor/ExternalSecret is **reverted within seconds**. To change them: push to the PUBLIC repo `main`, then `kubectl annotate application config-argo-events|config-argo-workflows -n argocd argocd.argoproj.io/refresh=hard --overwrite`; only then force the ESO re-sync + restart the eventsource pod. → `reference/testing-and-deploy.md`.
7. **A Workflow embeds the Sensor template as-of creation time — a Sensor edit does NOT change already-created Workflows.** After changing the Sensor, validate the fix on a **NEW** workflow created *after* the sync (`kubectl -n argo get wf <name> -o yaml | grep -c <marker>`), never an in-flight/older run. A "fix regression" is often just a run that fired with the old template. → `reference/agent-middle.md`.
8. **Multi-turn is per-message stateless** — the pipeline runs one Workflow per message, so a follow-up reply is classified/answered in isolation unless the thread is rebuilt. Every agent step calls `enterpriseclaw slack thread` (Slack `conversations.replies`) first; **requires a bot history scope** or it silently falls back to single-message and re-walls reads. The **toolless classifier drifts** on multi-turn transcripts unless `triage` wraps them in a classify-only directive. → `reference/agent-middle.md`.
9. **A new `main …` command the Workflow calls needs a new IMAGE** — the CLI is baked into `actions/enterpriseclaw/<ver>/Dockerfile`; adding a command means rebuild + repush + bump the Sensor's image tag (this session: `v0.1.0 → v0.1.1`). → `reference/agent-middle.md`.

## The one technique to remember — synthetic signed-event replay

You can drive the **entire** path (EventSource → Sensor → Workflow → reply) **without a human in Slack** by POSTing a properly-signed synthetic `event_callback` to `/slack`. The EventSource re-marshals it through slack-go exactly like a real delivery, so the dispatched schema is production-identical. Sign `v0:{ts}:{rawbody}` with the `signing_secret` and set the body's `token` to the `verification_token`. A fake `channel` (e.g. `C_DEMO`) still exercises everything up to Slack's API, returning `channel_not_found` — which itself proves the bot token is valid + egress works. Full recipe + the temporary `log`-trigger schema-discovery trick in → `reference/testing-and-deploy.md`.

## Files in the codebase

- EventSource + Sensor: [gitops/config/argo-events/slack-event-source.yaml](../../../gitops/config/argo-events/slack-event-source.yaml), [slack-external-secret.yaml](../../../gitops/config/argo-events/slack-external-secret.yaml), [slack-sensor.yaml](../../../gitops/config/argo-events/slack-sensor.yaml); VS path-split in [config/security/istio/argo-events/virtual-service.yaml](../../../gitops/config/security/istio/argo-events/virtual-service.yaml).
- Reply path: [cli/slack/main.nu](../../../cli/slack/main.nu) (+ [cli/tests/slack.test.nu](../../../cli/tests/slack.test.nu)); [gitops/config/argo-workflows/slack-bot-externalsecret.yaml](../../../gitops/config/argo-workflows/slack-bot-externalsecret.yaml).
- ALB `/slack` path generated by [cli/kube-tools/service-mesh/patches.nu](../../../cli/kube-tools/service-mesh/patches.nu); `slack-creds` registered in [cli/infra/vars.nu](../../../cli/infra/vars.nu) `secrets_registries`.

## Reference files

- **`reference/slack-app-config.md`** — the Slack-app-side prerequisites (Enable Events + Request URL, Subscribe to bot events `app_mention`, OAuth scopes, reinstall, invite the bot), and the credential shapes (the consolidated `slack-creds` secret + the two k8s secrets it feeds).
- **`reference/eventsource-sensor.md`** — the EventSource + Sensor manifests; the no-body-wrapper dispatch schema + gjson paths; the `type==app_mention` filter; structured field extraction; RBAC; the url_verification quirk.
- **`reference/reply-path.md`** — the reply loop: the `main slack reply` CLI command (pure payload builder + threading rule), the `slack-bot` ExternalSecret into ns `argo`, and the inline-Python Workflow reply step.
- **`reference/agent-middle.md`** — the triage-first branching DAG (triage/read/resolve/login/act + error-reply), multi-turn thread-transcript rebuild (`slack thread` + the history-scope prerequisite), the classifier-drift classify-only directive + Haiku-fence/empty-ADK-turn quirks, the Sensor-template timing race, and the CLI-baked-into-image version-bump coupling.
- **`reference/testing-and-deploy.md`** — synthetic signed-event replay (with a runnable script), the `log`-trigger schema-discovery trick, the `channel_not_found` plumbing check, and the ESO + Argo-self-heal deploy procedure.

## When NOT to use this

For the agent middle (kagent/agentgateway/MCP, JWT propagation) read the [kagent-trio skill](../kagent-trio/); for identity (Session-Broker `/identity/resolve`, the login wall) read the [session-broker skill](../session-broker/). This skill is the inbound-door + reply implementation reference only. The architecture-of-record is [CLAUDE.md](../../CLAUDE.md) §2.2.
