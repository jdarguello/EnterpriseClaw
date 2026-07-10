# kagent-postgresql interrupted-initdb corruption (+ controller / token-job cascade)

## Symptom chain

- `kagent` app **Synced but Degraded**.
- `kagent-postgresql-*` CrashLoopBackOff; log:
  ```
  PostgreSQL Database directory appears to contain a database; Skipping initialization
  postgres: could not find the database system
  Expected to find it in the directory "/var/lib/postgresql/data/pgdata",
  but could not open file ".../pg_control": No such file or directory
  ```
- `kagent-controller-*` CrashLoopBackOff; log: `database migration failed … dial tcp …:5432: connect: connection refused`.
- `mcp-discovery-token-init` / `mcp-discovery-token-refresh-*` Jobs **Failed** in ns `kagent`.
- Sometimes TWO postgres pods from the same ReplicaSet (one `Error`, one CrashLoop).

## Root cause

The postgres pod was **interrupted mid-`initdb` on first boot** (eviction, node
pressure, or a human/automation deleting it too early). That leaves a PGDATA dir on
the PV that is non-empty but has no `pg_control` — so every replacement pod *skips*
initialization and then can't open the half-built cluster. It never self-heals: the
corrupt state lives on the PersistentVolume, not in the pod.

A related corruption signature (seen when a pod was killed mid-init a SECOND time):
pod reaches Running but logs `database "kagent" does not exist` +
`xlog flush request … is not satisfied` + `could not write block … Multiple failures`.
Same remediation.

## Remediation (exact sequence that worked, 2026-07-10)

The DB is freshly-initialized state only — wiping it loses nothing on a new install.

1. Delete the corrupt volume and its pod. selfHeal will fight a scale-to-0, so just
   delete objects and let Argo recreate:
   ```sh
   kubectl delete pvc kagent-postgresql -n kagent --wait=false
   kubectl delete pod -n kagent -l app.kubernetes.io/name=kagent,app.kubernetes.io/component=database --wait=false
   ```
   The PVC hangs in `Terminating` (pvc-protection finalizer) until every pod
   referencing it is gone — if selfHeal spawns a replacement pod that grabs the
   dying PVC, delete that pod too. Once released, **Argo recreates the PVC fresh**
   (new volume ID) within ~1 min; confirm with `kubectl get pvc -n kagent`.
2. **CRITICAL — hands off the new pod.** Do NOT delete/restart it while it
   initializes; killing it mid-`initdb` re-corrupts the brand-new volume (this
   exact mistake was made once — a cleanup loop that deleted non-Running pods every
   10 s murdered the initializing pod). Wait for:
   ```sh
   kubectl logs -n kagent deploy/kagent-postgresql --tail=4
   # → "database system is ready to accept connections", no WAL/xlog errors
   ```
3. The controller recovers on its own, but its back-off tail is 5 min — skip it:
   ```sh
   kubectl delete pod -n kagent -l app.kubernetes.io/name=kagent,app.kubernetes.io/component=controller
   ```
   Verify it passes `running database migrations` and goes 1/1.

## Downstream: the mcp-discovery-token jobs

These jobs mint the MCP tool-discovery token **from Keycloak** (the
`kagent-controller` client) — they fail while Keycloak is down (see
[alb-webhook-races.md](alb-webhook-races.md) variant B, which co-occurred) and their
init job exhausts its backoff. Once Keycloak is 1/1:

```sh
kubectl delete job mcp-discovery-token-init -n kagent --ignore-not-found
kubectl create job mcp-discovery-token-manual --from=cronjob/mcp-discovery-token-refresh -n kagent
kubectl get secret mcp-discovery-token -n kagent   # must exist afterwards
```

That Secret matters beyond health: it is what un-gates the `act` → `platform-agent`
branch of the Slack workflow (CLAUDE.md §4).

## Durable fix (not yet done)

A Deployment-managed postgres with a bare PVC has no init-crash recovery. Options,
in increasing effort: an initContainer that wipes PGDATA when `pg_control` is
missing; or move to a StatefulSet/operator with proper init semantics. File as a
`bug` issue (Area: gitops) per the §7 workflow when picked up.