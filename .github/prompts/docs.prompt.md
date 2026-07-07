---
mode: agent
description: Load the docs conventions before generating or updating documentation pages.
---

# Docs

Use this when generating new documentation pages or updating existing ones under `docs/`
(the site is a Docusaurus scaffold today; the top-level README install sections are empty).

**Read `.claude/skills/docs/SKILL.md`** for the authoring conventions before writing, then
follow them. Keep pages consistent with the project's honest status framing — don't document
decided-but-unimplemented features as if they were done; verify against the area
instructions and the deep skill references (`/kagent-trio`, `/session-broker`,
`/slack-integration`) before asserting a capability. **Never reproduce secret values** in
examples — use placeholder key/field names.
