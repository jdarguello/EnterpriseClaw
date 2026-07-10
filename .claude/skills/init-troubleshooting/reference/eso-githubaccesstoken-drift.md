# agentic-mcps permanently OutOfSync — benign ESO GithubAccessToken drift

## Symptom

`agentic-mcps` shows **OutOfSync but Healthy**, forever. The only drifting resource:

```sh
kubectl get application agentic-mcps -n argocd -o json | python3 -c "
import json,sys
for r in json.load(sys.stdin)['status']['resources']:
    if r.get('status')!='Synced': print(r['kind'], r['name'])
"
# → GithubAccessToken github-app-token
```

## Root cause

ESO 0.10.5's `GithubAccessToken` v1alpha1 admission **silently prunes
`spec.repositories` and `spec.permissions`** from the live object, so live can never
match git. **Benign**: the token still mints, MCPServers stay Healthy. A manual sync
"fixes" it for seconds; the drift returns immediately.

## Why it came back after being fixed (the real lesson, 2026-07-10)

The fix — an `ignoreDifferences` block on the `agentic` ApplicationSet template — was
applied to the private sandbox repo on 2026-07-01 (`ebb9243`). A later
`enterpriseclaw init` **regenerated `agentic.yaml` via the CLI's "identifier
patches" step and clobbered it**, because the generator
(`app-of-apps agentic-appset` in [cli/gitops/app-of-apps.nu](../../../cli/gitops/app-of-apps.nu))
didn't emit the block. General rule: **manual commits to the vendored private repo
(`cli/gitops-config/`) do not survive re-init — durable fixes go in the CLI
generator or the public `gitops/` tree.**

## Current state (fixed durably 2026-07-10)

The generator itself now emits:

```yaml
ignoreDifferences:
  - group: generators.external-secrets.io
    kind: GithubAccessToken
    jsonPointers:
      - /spec/repositories
      - /spec/permissions
```

and the same block lives in the public `gitops/agentic-appset.yaml`. Every future
init emits it into the private repo's `agentic.yaml`.

## If it ever reappears

1. Check the live app actually carries the block:
   `kubectl get application agentic-mcps -n argocd -o jsonpath='{.spec.ignoreDifferences}'`
2. If empty, check the live ApplicationSet template, then the private repo's
   `agentic.yaml`, then the generator in `cli/gitops/app-of-apps.nu` — fix at the
   deepest layer that lost it and push. The live ApplicationSet is delivered by the
   **private** repo via the `main` app-of-apps with `selfHeal: true`, so a
   `kubectl edit` gets reverted — push to the private repo (and force a refresh:
   `kubectl annotate application main -n argocd argocd.argoproj.io/refresh=normal --overwrite`).
3. Also confirm the drift is still the harmless admission-prune (live
   `GithubAccessToken` spec missing exactly `repositories`/`permissions`) and not a
   new, real diff.