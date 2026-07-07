---
applyTo: "actions/**"
description: EnterpriseClaw vendored action images — generic, versioned containers for Argo Workflow steps.
---

# Action images (`actions/`)

You own everything under `actions/`: small, single-purpose container images that Argo
Workflow steps run as discrete, **generic** operations (e.g. `checkout`,
`create-github-app-token`). Anything **project-specific** belongs in the `enterpriseclaw`
CLI, not here — actions are deliberately generic and reusable.

## Directory layout (study the existing ones first)
- `actions/<name>/<version>/Dockerfile` — the pinned, versioned build. One folder per
  semver (e.g. `actions/checkout/5.0.0/`).
- `actions/<name>/<version>/.gitignore` — keep build artifacts/secrets out of git.
- `actions/<name>/README.md` — what the action does + a runnable `docker run` example with
  the env vars it needs.
- Optional `actions/<name>/tag.txt` — records the upstream tag/version pin.

Read `actions/checkout/README.md` and `actions/checkout/5.0.0/Dockerfile` as the canonical
reference for style and structure before doing anything.

## Conventions (match the existing images)
- Base images from `public.ecr.aws/docker/library/...` (ECR public mirror), pinned to an
  exact tag. **No unpinned `:latest`.**
- Pin the upstream action to an exact released tag; fetch its source by tarball
  (`curl -sSL .../archive/refs/tags/vX.Y.Z.tar.gz` + `tar --strip-components=1`) rather than
  cloning.
- Keep images minimal (`--no-cache`, `--omit=dev`, multi-step `RUN` chains as in the
  reference).
- Configured at runtime via environment variables (GitHub Actions convention: inputs arrive
  as `INPUT_*`, plus `GITHUB_*`/`RUNNER_*`). Use an `ENTRYPOINT` script.
- Write the README in the **same language and style as the existing action READMEs
  (currently Spanish)** — a short description, then a "Forma de uso" section with a
  copy-pasteable `docker run` example.

## Workflow — NEW action
1. **Find the source** (WebSearch/WebFetch): the upstream repo, latest stable release tag,
   and enough of its source (entrypoint, `action.yml`, dist) to understand inputs/outputs
   and runtime expectations.
2. **Build the image:** `actions/<name>/<version>/Dockerfile` per the conventions + a
   `.gitignore`; record the pin in `tag.txt`.
3. **Write the README:** `actions/<name>/README.md` with a concrete `docker run --rm ...`
   example wiring every env var and volume it needs.
4. **Test it** (below) and report the exact command + observed result.

## Workflow — UPDATE existing action
Update the latest version folder's `Dockerfile` (or cut a new `actions/<name>/<newversion>/`
for a meaningful upstream bump; in-place edits for fixes). **Test** per that action's
`README.md`; update the README if inputs/usage changed.

## Testing (always test before reporting done)
- Build with the local runtime (`docker build` or `podman build` — the repo's CLI uses
  podman; use whichever is present).
- Run it exactly as the README example shows, with **dummy/sandbox env values** (never real
  secrets). Confirm the expected effect (e.g. checkout populates the mounted volume).
- If a test needs a credential you don't have, say so and show the command you *would* run —
  don't fabricate secrets.

## Constraints
- **Never reproduce real secret values** — describe keys/fields only.
- Anything project-specific → the CLI area, not here.
