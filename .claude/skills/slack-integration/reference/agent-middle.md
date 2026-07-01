# The agent middle — triage-first branching + multi-turn context

The Slack Workflow is no longer an echo. Since **2026-07-01** it reasons: it classifies intent, answers read-only questions, and walls privileged actions behind Keycloak login. Source of truth (fully commented): [slack-sensor.yaml](../../../../gitops/config/argo-events/slack-sensor.yaml). All agent-calling steps run the `enterpriseclaw` image `…/credicorp-enterpriseclaw/enterpriseclaw:v0.1.1` from private ECR.

## The DAG

```
main (DAG)
├── log        busybox audit echo (always; independent — a log failure never blocks the reply)
├── triage     A2A → general-classifier → outputs.parameters.category = "read-only" | "action"
├── read        when category==read-only  → A2A → github-reader → slack reply   (workload rail, no JWT)
├── resolve     when category==action     → broker /identity/resolve → outputs {has_token, token}
├── login        when resolve.has_token==false → broker /auth/login/start → reply login URL (THE WALL)
└── act          when resolve.has_token==true  → A2A via agentgateway (Bearer=user JWT) → platform-agent → reply
onExit: error-reply  (posts a generic apology when workflow.status != Succeeded)
```

Branching is on the **output VALUE**, not step success: `resolve-step` exits 0 even when `has_token=false`, and the DAG `when:` reads `{{tasks.resolve.outputs.parameters.has_token}}`. The login wall is **conditional on intent** (`category==action` + no token), NOT on mere auth state — a read-only question is answered anonymously; only an action with no cached token gets walled.

Agent endpoints:
- `triage`  → `http://general-classifier.kagent:8080`  (toolless; Claude Haiku 4.5)
- `read`    → `http://github-reader.kagent:8080`        (read-only issues MCP, workload rail)
- `resolve`/`login` → `http://session-broker.session-broker.svc.cluster.local` (broker `/identity/resolve`, `/auth/login/start`)
- `act`     → `http://agentic-a2a-gw.kagent:8080/platform-agent` (VIA agentgateway; Bearer = user JWT)

## Multi-turn context — the pipeline is per-message stateless

One Workflow runs **per inbound message**. A follow-up reply ("the owner is jdarguello") therefore reaches the classifier/agent **in isolation** — unclassifiable → historically defaulted to `action` → wrongly walled. Fix (matches the §2.2 "conversation state lives in Slack thread history, rebuilt each turn" decision): every agent-calling step (`triage`, `read`, `act`) rebuilds the whole thread first:

```nu
let convo = (
  try {
    enterpriseclaw slack thread --channel $env.SLACK_CHANNEL --ts $env.SLACK_TS \
      --thread-ts $env.SLACK_THREAD_TS --token $env.SLACK_BOT_TOKEN --out /tmp/thread.txt
    let t = (open /tmp/thread.txt | str trim)
    if ($t | is-empty) { $env.USER_TEXT } else { $t }
  } catch { $env.USER_TEXT }   # fall back to the single message — single-turn never regresses
)
```

`main slack thread` (in [cli/slack/main.nu](../../../../cli/slack/main.nu)) calls Slack `conversations.replies` and renders a `User:/Assistant:` transcript (pure helper `slack thread-transcript`; role = Assistant if `bot_id`/`app_id`/`subtype==bot_message`; strips `<@U…>` mentions; drops system subtypes).

**⚠️ HARD PREREQUISITE:** the bot token must hold a **history scope** (`channels:history`/`groups:history`/`im:history`/`mpim:history`). Without it `conversations.replies` returns `missing_scope`, the `try` falls back to single-message, and multi-turn silently regresses to the old walling behavior. (Add the scopes in the Slack app → reinstall; the token value is unchanged.)

## Classifier drift — wrap the transcript with a classify-only directive

Feeding the **toolless** classifier a multi-turn transcript that ends mid-clarification (an Assistant turn asking for info) makes it **drift**: it continues the conversation (asks its *own* question) instead of emitting the category JSON → no JSON → fail-close to `action` → wrongly walls a read. `triage-step` therefore wraps `$convo`:

```nu
let classify_msg = $"You are an intent classifier. Below is a Slack conversation transcript. Classify ONLY the intent of the LAST user message, using earlier turns as context. Do NOT answer, continue, or ask any question. Output ONLY the category JSON.\n\n=== CONVERSATION ===\n($convo)\n=== END ==="
```

Only `triage` wraps; `read`/`act` pass raw `$convo` (they *should* answer/act). Verified robust across greeting / action / answer-follow-up / drift cases → all emit valid category JSON.

Two more classifier quirks handled in-step:
- **Haiku markdown fences.** The classifier is told to emit bare JSON but Haiku intermittently wraps it in a ` ```json ` fence. The parser extracts the first `{…}` with `str replace --regex '(?s)^[^{]*(\{.*\})[^}]*$' '$1'` before `from json`; any failure fail-closes to `action`.
- **Empty ADK turn → node fails.** kagent/ADK agents intermittently return an empty A2A task in state `input-required` instead of `completed`, so `a2a call` exits non-zero. `triage` and `read` carry `retryStrategy` (limit 3, backoff 2s×2). **`act` is deliberately NOT retried** — it mutates/opens PRs, so a retry after partial success could double-act; it fail-closes to `error-reply` instead.

## ⚠️ The timing race — a Workflow embeds the Sensor template as-of creation time

An Argo Workflow created by the Sensor embeds a **copy** of the Sensor's `triggers[].template` spec **as it was at creation time**. Updating the Sensor CRD (via GitOps sync) does **NOT** retroactively change an already-created Workflow. During this session a turn-2 login-wall failure looked like a fix regression — it was actually a workflow that fired **before** the classify-directive edit had synced, so it ran the *old* template. **When validating a Sensor change, confirm the fix by inspecting a NEW workflow created after the sync**, e.g. `kubectl -n argo get wf <name> -o yaml | grep -c classify_msg` and `… | grep -c enterpriseclaw:v0.1.1`. Don't judge the fix from an in-flight/older run.

## Version-bump coupling — a new CLI command means a new image

The `enterpriseclaw` CLI is **baked into the container image** (`actions/enterpriseclaw/<version>/Dockerfile` COPYs the `cli/` tree). So adding a `main …` command the Workflow calls (e.g. `slack thread`) **requires a rebuild + repush + a version bump in the Sensor**. This session bumped `v0.1.0 → v0.1.1`. Build from repo ROOT, linux/amd64 (all nodes are amd64), the Dockerfile only downloads a prebuilt nushell binary:
`podman build --platform linux/amd64 -f actions/enterpriseclaw/v0.1.1/Dockerfile -t 158623290227.dkr.ecr.us-east-1.amazonaws.com/credicorp-enterpriseclaw/enterpriseclaw:v0.1.1 .`

## Injection safety (unchanged, still enforced)

User-controlled text is **never interpolated** into a command/args string — it arrives only as env values (`$env.USER_TEXT`) or files. All `enterpriseclaw` steps use `command: [nu, -c]` so nushell receives the script as one safe argument. The user JWT and broker token live in files/env, never echoed or logged.
