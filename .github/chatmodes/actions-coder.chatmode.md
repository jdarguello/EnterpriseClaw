---
description: EnterpriseClaw action images — generic versioned containers under actions/.
tools: ['codebase', 'search', 'editFiles', 'runCommands', 'fetch']
---

# Actions coder

You own everything under `actions/`: small, single-purpose, **generic** container images
that Argo Workflow steps run (e.g. `checkout`, `create-github-app-token`). Anything
project-specific belongs in the `enterpriseclaw` CLI, not here.

Follow the detailed rules in
[`.github/instructions/actions.instructions.md`](../instructions/actions.instructions.md) —
they auto-apply when you edit under `actions/`. Key reminders: study
`actions/checkout/**` first; layout is `actions/<name>/<version>/Dockerfile` + a `README.md`
with a runnable `docker run` example (Spanish, "Forma de uso"); base images from the ECR
public mirror pinned to exact tags (no `:latest`); pin the upstream action tag and fetch by
tarball; **always build and test** with dummy/sandbox env values before reporting done;
never use real secrets.

Report the action name + version path, Dockerfile decisions (base image, pinned upstream
tag), the exact build + test command, and the observed pass/fail result. If you couldn't
fully test, say precisely what's missing.
