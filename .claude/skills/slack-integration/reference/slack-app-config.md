# Slack app configuration + credential shapes

## Slack-app-side prerequisites (the human-in-Slack-UI steps)

Done once per Slack app. Without these, Slack only sends `url_verification` — no real events.

1. **Event Subscriptions** → **Enable Events: On**.
2. **Request URL** = `https://events.<domain>/slack` (same host/ALB as the github webhook, split by the `/slack` path). Slack POSTs a `url_verification` challenge and the endpoint must echo it → goes **Verified ✓**. (See the url_verification quirk in `eventsource-sensor.md` — the trailing `success` does NOT block Slack.)
3. **Subscribe to bot events** → add **`app_mention`** → **Save Changes**. *This is the switch that actually makes Slack send messages.* (Slack auto-adds the `app_mentions:read` scope.)
4. **OAuth & Permissions → Bot Token Scopes**: `app_mentions:read` (receive mentions) + `chat:write` (post replies). `chat:write.customize` is optional (post as a custom name/avatar).
5. **Reinstall** the app to the workspace after any scope change (green "Reinstall to <workspace>" button). The bot token does **not** change on reinstall.
6. **Invite the bot to the channel**: `/invite @YourApp`. `app_mention` only fires in conversations the bot is a member of. (A reply to a channel the bot is not in returns `channel_not_found`.)

Trigger model chosen for the demo = **`app_mention`** (cleanest, least noisy; bot only sees messages that mention it). The alternative `message.channels`/`message.im` is a firehose needing `channels:history`/`im:history` + self-trigger-loop filtering — not used.

What you do NOT need for this bot: token rotation (leave OFF — it would expire the static token the EventSource holds), PKCE, and Redirect URLs (those belong to the Session-Broker's *user-login* OAuth flow, a separate component — not this message bot).

## Credential shapes (described, never reproduce values)

One consolidated AWS Secrets Manager secret **`slack-creds`** holds all Slack-app credentials as a single JSON blob with **snake_case** keys:

| SM property | what | from |
|---|---|---|
| `verification_token` | legacy token the EventSource validates the payload against | Slack → Basic Information → App Credentials |
| `signing_secret` | HMAC request-signature secret (32 hex chars) | same |
| `bot_oauth_token` | `xoxb-…` bot token (reply path) | OAuth & Permissions → Bot User OAuth Token |
| `client_id`, `client_secret` | OAuth app creds (future) | Basic Information |

`slack-creds` is **read-referenced, not auto-generated** (values originate in Slack), so it MUST pre-exist in SM AND be listed in `secrets_registries` ([cli/infra/vars.nu](../../../cli/infra/vars.nu)) or the secrets-manager module's exact-ARN read policy denies it (`could not get secret data from provider`). A standalone `slack-bot-token` SM secret from an earlier step is now **redundant** — the bot token lives in `slack-creds`.

Two k8s Secrets are materialized from `slack-creds` by ExternalSecrets (ClusterSecretStore `git-creds-secretstore`), renaming the snake_case SM properties to the keys each consumer expects:

| k8s Secret (ns) | keys ← SM property | consumed by |
|---|---|---|
| `slack-secret` (argo-events) | `token`←`verification_token`, `signingSecret`←`signing_secret`, `botToken`←`bot_oauth_token` | the EventSource |
| `slack-bot` (argo) | `botToken`←`bot_oauth_token` | the Workflow reply step |

Manifests: [slack-external-secret.yaml](../../../gitops/config/argo-events/slack-external-secret.yaml) (argo-events) and [slack-bot-externalsecret.yaml](../../../gitops/config/argo-workflows/slack-bot-externalsecret.yaml) (argo). The bot token in both flows from the **one** SM property `bot_oauth_token` (single source of truth).

**Gotcha (ESO property names):** the ExternalSecret's `remoteRef.property` must match the SM JSON keys exactly. When `slack-creds` was reshaped from flat `token`/`signingSecret` to snake_case, the ExternalSecrets had to be repointed (`token`→`verification_token`, `signingSecret`→`signing_secret`), else ESO errors `key token does not exist in secret slack-creds`.
