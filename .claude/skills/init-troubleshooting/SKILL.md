---
name: init-troubleshooting
description: >-
  Runbook for the recurring `enterpriseclaw init` app-health failures — the known
  post-init symptoms (Argo CD apps stuck OutOfSync/Degraded/Progressing), how to
  diagnose each to its root cause, and the exact remediation that worked live.
  Use whenever a fresh init leaves apps unhealthy: ALB-webhook sync races (incl.
  the wedged keycloak sync operation), istio-ingress image:auto ImagePullBackOff,
  the benign agentic-mcps ESO drift, kagent-postgresql interrupted-initdb
  corruption (and its downstream controller / mcp-discovery-token failures).
  All of these stem from the CLAUDE.md §6 "no sync-wave / no readiness-gate"
  fragility, so expect them on EVERY fresh init until that is fixed.
---

# `enterpriseclaw init` troubleshooting runbook

After `enterpriseclaw init`, some Argo CD apps routinely fail to converge. These are
**known, repeatable failure modes** (each diagnosed + fixed live at least once), not
mysteries — triage with the table below, then follow the matching reference file.

## First command — always start here

```sh
cd cli && eval "$(devbox shellenv)"   # loads kubeconfig ctx + GH_TOKEN from cli/.env
kubectl get applications -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
  | grep -vE 'Synced\s+Healthy'
```

Anything listed is a patient. For each, pull the per-resource detail before acting —
the app-level status usually hides the real error:

```sh
kubectl get application <app> -n argocd -o json | python3 -c "
import json,sys
app=json.load(sys.stdin)
op=app['status'].get('operationState',{})
print('op:', op.get('phase'), op.get('startedAt'), '|', op.get('message','')[:200])
for r in op.get('syncResult',{}).get('resources',[]):
    if r.get('status')!='Synced': print(r['kind'], r['name'], r.get('status'), '-', r.get('message','')[:160])
"
```

## Triage table (symptom → failure mode)

| Symptom | Failure mode | Reference |
|---|---|---|
| `config-istio` / `config-kagent-ui` / `config-session-broker` OutOfSync, `x509: certificate signed by unknown authority` on `vingress.elbv2.k8s.aws` | ALB webhook cert race (variant A) | [alb-webhook-races.md](reference/alb-webhook-races.md) |
| `keycloak` OutOfSync/Progressing for 30+ min, op stuck "waiting for healthy state of StatefulSet/keycloak", `keycloak-0` crash-looping on `cannot resolve host "keycloak-postgresql"`, **no Services in the keycloak ns** | ALB webhook race (variant B) → Services never created → **wedged sync op** | [alb-webhook-races.md](reference/alb-webhook-races.md) |
| `istio-ingress` Degraded, gateway pod `ImagePullBackOff` on image literally named `auto` | istiod injection-webhook race | [istio-ingress-image-auto.md](reference/istio-ingress-image-auto.md) |
| `agentic-mcps` permanently OutOfSync but Healthy; only drifting resource is `GithubAccessToken/github-app-token` | benign ESO admission-prune drift (harmless, but fix the missing `ignoreDifferences`) | [eso-githubaccesstoken-drift.md](reference/eso-githubaccesstoken-drift.md) |
| `kagent` Degraded; `kagent-postgresql` CrashLoopBackOff with `pg_control: No such file or directory`; `kagent-controller` CrashLoopBackOff (`connection refused` to postgres); `mcp-discovery-token-*` jobs Failed | interrupted-initdb PGDATA corruption + downstream cascade | [kagent-postgres-corruption.md](reference/kagent-postgres-corruption.md) |
| Service/Ingress apps (`argo-workflows`, `redis`, `config-istio`) stuck with op `Running`, retries `5/5`, `failed calling webhook "*.elbv2.k8s.aws" … connection refused`; ALB pods younger than the failed ops | ALB webhook race, retry budget exhausted before controller was up — clear `operationState` on each once webhook endpoints exist (2026-07-14) | [alb-webhook-races.md](reference/alb-webhook-races.md) |
| `session-broker` pod `1/1` with only one container despite `dapr.io/enabled: true`; Dapr control plane healthy and injecting OTHER pods | pod admitted before the Dapr injector was serving (`failurePolicy: Ignore` hides it) — happens on every fresh init; `kubectl delete pod -n session-broker <pod>` → recreated `2/2` | memory `dapr-sidecar-injector-sg-port` (trigger 2) |
| `alb-controller` permanently OutOfSync on `aws-load-balancer-tls` Secret + webhook `caBundle` | chart `genSignedCert` re-renders a fresh cert every render; selfHeal re-syncs stomp the live cert (a *cause* of the x509 race). **Durable fix LANDED 2026-07-14:** `ignoreDifferences` + `RespectIgnoreDifferences=true` in the public `helm-app.yaml` | [alb-webhook-races.md](reference/alb-webhook-races.md) |
| Slack workflow triage step fails `A2A transport error: DNS Error`; `kubectl get agents -n kagent` shows `ACCEPTED: False` with `ReconcileFailed … failed calling webhook "mservice.elbv2.k8s.aws"`; no `general-classifier`/`github-reader` Services in ns `kagent` | the ALB webhook race hits the **kagent controller's per-Agent Service creates** too — Agents wedge at `Accepted: False` and the controller does NOT retry on its own (`Ready: True` is misleading; the Deployment exists, the Service doesn't). Fix (2026-07-14): delete the kagent-controller pod **BY NAME** (`kubectl get pods -n kagent \| grep controller`) — do NOT use `-l app.kubernetes.io/name=kagent`, that selector also matches `kagent-postgresql` (initdb-corruption risk!) and `kagent-ui`. On restart it re-reconciles; Agents flip `Accepted: True` and the Services appear in ~1 min. In-flight workflows recover on their next retry; retry-exhausted ones must be re-triggered from Slack. | — |
| Slack workflow stuck: triage pod `ImagePullBackOff`, pull error `not found` on `…/credicorp-enterpriseclaw/enterpriseclaw:v0.1.1` | **destroy/init wipes ECR images** — `tofu destroy` removes the repos (images included), init recreates them EMPTY, and the CLI's container build path is broken (§4), so nothing repushes them. Rebuild+push manually with the Devbox podman (2026-07-14): `podman machine start` → `aws ecr get-login-password \| podman login --username AWS --password-stdin <acct>.dkr.ecr.<region>.amazonaws.com` → `podman build --platform linux/amd64 -f actions/enterpriseclaw/<ver>/Dockerfile -t <full-ecr-ref> .` (context = REPO ROOT — it COPYs `cli/`; the two `actions/*` images use their own dir as context) → `podman push`. Same for `checkout:5.0.0` + `create-github-app-token:2.1.4`. The stuck workflow self-recovers: no `activeDeadlineSeconds`, kubelet re-pulls within ≤5 min of the push. | — |

## Cross-cutting rules (learned the hard way)

- **Fix order matters when several coexist:** postgres/PVC first (it gates
  `kagent-controller`), keycloak Services next (Keycloak gates the
  `mcp-discovery-token` jobs), token job last. The ESO drift is independent.
- **Argo selfHeal fights you.** `kubectl scale --replicas=0` and `kubectl edit` are
  reverted within seconds. Work *with* it: delete pods/PVCs and let Argo recreate
  them from git, or land the change in the repo it syncs from.
- **Never kill a postgres pod that might be mid-`initdb`.** That is what corrupts
  the volume in the first place (self-inflicted once, 2026-07-10). After a PVC
  wipe, leave the new pod alone until its log says `database system is ready`.
- **A sync op can hang forever** on "waiting for healthy state of ..." when the
  resources that would make it healthy FailedSyncFailed in the same op. Neither a
  `phase: Terminating` status patch nor restarting
  `argo-cd-argocd-application-controller` reliably clears it; what works is
  clearing the state so automated sync starts fresh:
  `kubectl patch application <app> -n argocd --type merge -p '{"status":{"operationState":null}}'`
- **CrashLoopBackOff back-off is 5 min at the tail** — after fixing the underlying
  cause, delete the crash-looping pod instead of waiting.
- **The vendored private repo (`cli/gitops-config/`) is regenerated by init** —
  manual fixes committed only there get clobbered by the next init's
  "identifier patches". Durable fixes go in the CLI generators
  (`cli/gitops/*.nu`) or the public `gitops/` tree.
- Root-cause context: CLAUDE.md §6 — the GitOps tree has **no sync-wave /
  readiness gating** between ALB controller ↔ Ingress/Service consumers and
  istiod ↔ gateway pods. Until that lands, expect these on every fresh init.