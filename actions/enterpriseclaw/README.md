# enterpriseclaw

Packages the **EnterpriseClaw Nushell CLI** as a container image so Argo Workflow steps can
invoke it in-cluster without a Devbox environment. The image bundles Nushell 0.112.2 (pinned to
match `cli/devbox.json`) plus the full `cli/` module tree, and exposes the CLI as the container
entrypoint.

## Commands exposed to Argo Workflow steps

Nushell multi-word command dispatch: the script defines commands named `main slack reply`, `main
a2a call`, etc. When run as a container, the `main` prefix is the script-level dispatcher — so
Argo passes the subcommand WITHOUT the leading `main` (i.e. `args: [slack, reply, ...]` not
`args: [main, slack, reply, ...]`).

| Argo step args | Purpose |
|---|---|
| `slack reply --channel C0... --text "..." --ts 17... --thread-ts 17...` | Post a reply back into a Slack thread (chat.postMessage). Needs `SLACK_BOT_TOKEN`. |
| `slack thread --channel C0... --ts 17... --thread-ts 17... --out /tmp/thread.txt` | Rebuild a Slack thread's conversation as a plain-text transcript (conversations.replies) so an agent gets multi-turn context. Needs `SLACK_BOT_TOKEN` and the `channels:history`/`groups:history`/`im:history`/`mpim:history` bot scope(s). |
| `a2a call --url https://agentgateway/... --message "..." --out /tmp/out.json` | A2A JSON-RPC `message/send` to agentgateway/kagent. Bearer token via `--token` or `BEARER_TOKEN`. |
| `broker resolve --slack-user-id U0... --url https://broker/identity/resolve` | Call Session-Broker `POST /identity/resolve` to exchange a Slack user ID for a JWT. |
| `broker login-start --slack-user-id U0... --channel C0... --ts 17...` | Call Session-Broker `POST /auth/login/start` and post the Keycloak `/authorize` URL to Slack. |

Argo Workflow step shape:

```yaml
- name: slack-reply
  container:
    image: <ECR_REGISTRY>/enterpriseclaw/enterpriseclaw:v0.1.1
    command: [enterpriseclaw]
    args:
      - slack
      - reply
      - --channel
      - "{{inputs.parameters.channel}}"
      - --text
      - "{{inputs.parameters.text}}"
      - --ts
      - "{{inputs.parameters.ts}}"
      - --thread-ts
      - "{{inputs.parameters.thread_ts}}"
    env:
      - name: SLACK_BOT_TOKEN
        valueFrom:
          secretKeyRef:
            name: slack-bot
            key: SLACK_BOT_TOKEN
```

A2A call step:

```yaml
- name: a2a-call
  container:
    image: <ECR_REGISTRY>/enterpriseclaw/enterpriseclaw:v0.1.1
    command: [enterpriseclaw]
    args:
      - a2a
      - call
      - --url
      - "http://general-classifier.kagent:8080"
      - --message
      - "{{inputs.parameters.text}}"
      - --token
      - "{{inputs.parameters.user_jwt}}"
      - --out
      - /tmp/out.json
```

## Build context

The image must be built from the **repository root** (not from inside `actions/`), because the
Dockerfile COPYs `cli/` which lives at the root level:

```bash
podman build \
  --platform linux/amd64 \
  -f actions/enterpriseclaw/v0.1.1/Dockerfile \
  -t enterpriseclaw:v0.1.1 \
  .
```

For a multi-arch manifest (amd64 + arm64):

```bash
podman build \
  --platform linux/amd64,linux/arm64 \
  -f actions/enterpriseclaw/v0.1.1/Dockerfile \
  -t enterpriseclaw:v0.1.1 \
  .
```

**Changelog:** v0.1.1 = v0.1.0 + the `slack thread` command (`main slack thread` in
`cli/slack/main.nu`). No Dockerfile logic changed — this is a pure CLI version bump so Argo
Workflow steps can pull the updated `cli/` tree with the new subcommand baked in.

## Forma de uso (self-test)

Verify nushell version:

```bash
podman run --rm --entrypoint nu enterpriseclaw:v0.1.1 --version
# expected: 0.112.2
```

Top-level CLI help (confirms the full module chain sourced successfully and lists all subcommands):

```bash
podman run --rm enterpriseclaw:v0.1.1 -h
```

Slack reply subcommand help:

```bash
podman run --rm enterpriseclaw:v0.1.1 slack reply -h
```

Slack thread subcommand help:

```bash
podman run --rm enterpriseclaw:v0.1.1 slack thread -h
```

Slack reply (requires a real bot token and channel; replace values with sandbox placeholders for
smoke-testing):

```bash
podman run --rm \
  -e SLACK_BOT_TOKEN=xoxb-YOUR-TOKEN \
  enterpriseclaw:v0.1.1 \
  slack reply \
    --channel C0123ABC \
    --text "hello from the container" \
    --ts "1234567890.000100"
```

Slack thread fetch (rebuild a thread transcript):

```bash
podman run --rm \
  -e SLACK_BOT_TOKEN=xoxb-YOUR-TOKEN \
  enterpriseclaw:v0.1.1 \
  slack thread \
    --channel C0123ABC \
    --ts "1234567890.000100" \
    --thread-ts "1234567890.000100" \
    --out /tmp/thread.txt
```
