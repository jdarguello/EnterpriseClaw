# Reply path (the outbound half — closing the loop)

The Workflow posts its answer back into the **originating Slack thread** via `chat.postMessage`. Three pieces.

## 1. Bot token into ns `argo` — the `slack-bot` ExternalSecret

Workflows run in ns **`argo`**, but the EventSource's `slack-secret` (with the bot token) is in ns **`argo-events`**, and k8s Secrets are namespace-scoped. So a **separate ExternalSecret** ([slack-bot-externalsecret.yaml](../../../gitops/config/argo-workflows/slack-bot-externalsecret.yaml)) materializes the same `slack-creds/bot_oauth_token` into ns `argo` as Secret **`slack-bot`** key **`botToken`** (ClusterSecretStore `git-creds-secretstore`). It's registered in [config/argo-workflows/kustomization.yaml](../../../gitops/config/argo-workflows/kustomization.yaml).

## 2. The `main slack reply` CLI command ([cli/slack/main.nu](../../../cli/slack/main.nu))

The **canonical home** for the reply logic. Split into a PURE, unit-tested payload builder + a thin IO command:

- `slack reply-payload --channel --text --ts --thread-ts` → returns the chat.postMessage body record. **Threading rule:** reply in-thread under the mention — `thread_ts` = the mention's `thread_ts` if set (mention was inside a thread), else its own `ts` (top-level mention); if both empty, omit `thread_ts` (channel-level post). Tested in [cli/tests/slack.test.nu](../../../cli/tests/slack.test.nu) (registered in `tests/run.nu`).
- `main slack reply --channel --text --ts --thread-ts [--token]` → builds the body and `http post`s to `https://slack.com/api/chat.postMessage` with `Authorization: Bearer <botToken>` (from `--token` or `$env.SLACK_BOT_TOKEN`). Raises on Slack's logical failures (HTTP 200 + `{ok:false,error:…}`).

Nushell 0.112.2: `http post --content-type "application/json" --headers { Authorization: $"Bearer ($t)" } <url> ($body | to json)`.

## 3. The Workflow reply step (inline Python)

**Why not the CLI command?** There is **no `enterpriseclaw` workflow image** (CLI is a local Devbox tool; the container build path is broken — CLAUDE.md §4). The existing workflow steps run *vendored action images*, not the CLI. So the reply step is **inline Python** (`public.ecr.aws/docker/library/python:3.12-slim`) that mirrors the CLI command — `json.dumps` gives safe escaping of arbitrary user text, which a shell `curl` step would mangle. Swap to `enterpriseclaw main slack reply …` once a CLI image exists.

The Workflow (embedded in the Sensor trigger, [slack-sensor.yaml](../../../gitops/config/argo-events/slack-sensor.yaml)) is a DAG `main`:
- `log` — busybox echo of the five parsed fields (audit/debug).
- `reply` — the Python step. Reads `SLACK_BOT_TOKEN` (from `secretKeyRef: {name: slack-bot, key: botToken}`), `SLACK_CHANNEL`/`SLACK_TS`/`SLACK_THREAD_TS`/`USER_TEXT` (workflow params). Computes `thread = thread_ts or ts`, strips a leading `<@…>` mention from the text, posts `chat.postMessage`, prints `ok=/error=/ts=`, and `raise SystemExit` on `ok:false`.

Tasks are independent (no `dependencies:`) so a `log` hiccup can't block the actual reply.

Image choice rationale: `public.ecr.aws/...` images avoid Docker Hub pull-rate limits on EKS nodes. Egress to `slack.com:443` works through NAT (and Istio ambient passes external egress).

## Verified behavior

- Real mention in a channel the bot is in → `chat.postMessage ok=True`, reply appears **in-thread**.
- Synthetic event with a fake channel (`C_DEMO`) → `ok=False error=channel_not_found` — proves the token is valid (a bad token returns `not_authed`/`invalid_auth`) + egress + secret mount, without needing a real channel. See `testing-and-deploy.md`.
