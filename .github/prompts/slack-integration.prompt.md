---
mode: agent
description: Load the Slack-door reference before touching the Argo Events Slack EventSource / Sensor / reply Workflow.
---

# Slack integration reference

Use this when extending, debugging, or testing the **Slack inbound door** — the Argo Events
Slack **EventSource** (`/slack`), the **`slack-mention` Sensor**, and the per-message Argo
**Workflow** that replies back into the thread; when touching `slack-creds` / the
`slack-secret` / `slack-bot` ExternalSecrets; when authoring the Sensor/Workflow or the
`main slack reply` CLI command; or when building the **agent middle** (Step 0 → A2A →
reply) on top of it.

The Slack door is **LIVE incl. the agent middle** (triage → read-only answers → login wall
with Google federation). Conversation state is **stateless / per-message** — rebuilt each
turn from Slack thread history via `conversations.replies` (`enterpriseclaw slack thread`).

**Read these repo files before answering or editing** (they cover schema gotchas that waste
hours and the synthetic-signed-event replay technique for testing without a human in Slack):
- `.claude/skills/slack-integration/SKILL.md` (overview + entry points)
- `.claude/skills/slack-integration/reference/slack-app-config.md` (Slack app / scopes / tokens)
- `.claude/skills/slack-integration/reference/eventsource-sensor.md` (EventSource + Sensor schema)
- `.claude/skills/slack-integration/reference/agent-middle.md` (triage → A2A → broker → reply DAG)
- `.claude/skills/slack-integration/reference/reply-path.md` (`main slack reply` round-trip)
- `.claude/skills/slack-integration/reference/testing-and-deploy.md` (replay testing + deploy)

Remember: the Slack token used by the EventSource is the **Verification Token** (not the bot
token); `url_verification` returns `<challenge>success`. **Never reproduce secret values.**
Cross-reference `/session-broker` for Step 0 and the login wall.
