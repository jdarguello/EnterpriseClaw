# ALB webhook races (two variants) — Services/Ingresses fail to apply during init

Both variants share one root cause: **the AWS Load Balancer Controller's mutating/
validating webhooks (`*.elbv2.k8s.aws`) intercept every Service and Ingress apply
cluster-wide, and Argo CD syncs those resources before the controller is serving.**
There is no sync-wave gating the consumers behind the controller (CLAUDE.md §6).
The apply fails, the app's retry budget exhausts, and depending on *which* resources
failed, the blast radius differs.

## Variant A — Ingress apps OutOfSync on x509 (`config-istio`, `config-kagent-ui`, `config-session-broker`)

- **Symptom:** `SyncError` with
  `failed calling webhook "vingress.elbv2.k8s.aws" … x509: certificate signed by unknown authority`.
- **Root cause:** the controller mints its self-signed webhook cert and patches the
  webhook `caBundle` at startup; Argo applied Ingresses while serving-cert ≠ caBundle.
- **Diagnose:** confirm the race is over — the secret and the webhook must agree, and
  a dry-run apply must pass:
  ```sh
  kubectl get secret aws-load-balancer-tls -n alb-controller -o jsonpath='{.data.ca\.crt}' | md5
  kubectl get mutatingwebhookconfiguration aws-load-balancer-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | md5
  kubectl apply --dry-run=server -f <any-ingress.yaml>
  ```
- **Fix:** once consistent, just re-trigger sync of the failed apps (or wait for the
  automated retry).

## Variant B — keycloak wedged: Services never created + sync op hangs (2026-07-10)

The nastier variant, because the failure **freezes the sync operation itself**.

- **Symptom chain:**
  - `keycloak` app OutOfSync/Progressing for 30+ minutes; op message:
    `waiting for healthy state of apps/StatefulSet/keycloak`.
  - `kubectl get svc -n keycloak` → **No resources found** (all 4 Services missing:
    `keycloak`, `keycloak-headless`, `keycloak-postgresql`, `keycloak-postgresql-hl`).
  - `keycloak-0` CrashLoopBackOff; log:
    `cannot resolve host "keycloak-postgresql": lookup … no such host`.
  - `keycloak-postgresql-0` is Running 1/1 (the StatefulSets applied fine!).
- **Root cause:** during the sync, all 4 Services hit
  `failed calling webhook "mservice.elbv2.k8s.aws": failed to call webhook: Post "https://aws-load-balancer-webhook-service…": connection refused`
  (controller not serving yet) → `FailedSyncFailed`. The StatefulSets applied, so the
  op sits waiting for Keycloak health — **a deadlock**: Keycloak needs the postgres
  Service's DNS, which the op will never re-apply. The op hangs indefinitely; Argo
  will not start a new automated sync while one is Running.
- **Diagnose:** dump `status.operationState.syncResult.resources` (see SKILL.md
  snippet) — the four Services show `Failed/SyncFailed` with the webhook error, and
  `startedAt` is old.
- **Fix (exact sequence that worked):**
  1. Verify the ALB webhook is NOW healthy (it will be, minutes after init):
     ```sh
     kubectl get endpoints -n alb-controller aws-load-balancer-webhook-service   # must list pod IPs
     ```
  2. Kill the wedged op. **Do NOT bother with** `phase: Terminating` patches or
     restarting `argo-cd-argocd-application-controller` — both were tried live and
     the op stayed `Terminating` indefinitely. What works:
     ```sh
     kubectl patch application keycloak -n argocd --type merge -p '{"status":{"operationState":null}}'
     ```
     Automated sync (the app has `automated.selfHeal`) starts a fresh op within ~1 min.
  3. Confirm the 4 Services appear: `kubectl get svc -n keycloak`.
  4. Skip keycloak's crash-loop back-off: `kubectl delete pod keycloak-0 -n keycloak`.
     It boots in ~80–90 s (slow Quarkus first boot is NORMAL — a couple of
     `/realms/master` connection-refused probes are not a crash).
  5. If the `mcp-discovery-token-*` jobs in ns `kagent` had been failing, re-run them
     now — they mint their token FROM Keycloak (see
     [kagent-postgres-corruption.md](kagent-postgres-corruption.md) §downstream).

## Durable fix (not yet done)

Sync-wave / health-gate the ALB controller ahead of every Service/Ingress consumer,
or scope its webhooks with an `objectSelector` so unrelated namespaces don't depend
on its availability. Tracked conceptually under CLAUDE.md §6; file as a `bug` issue
per the §7 Issues→PRs workflow when picked up.