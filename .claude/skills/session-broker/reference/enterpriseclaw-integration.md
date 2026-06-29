# EnterpriseClaw ↔ Session-Broker integration

How `enterpriseclaw init` installs and internet-exposes the broker. **Implemented 2026-06-26.** All of
it is **declarative GitOps** (private repo → Argo CD app-of-apps), so `enterpriseclaw destroy` prunes it.

## Where it hooks in

The CLI's job is to **generate the private repo's overlays** before pushing them (CLAUDE.md §5). All of
this runs inside [`main kube-tools bootstrap`](../../../../cli/kube-tools/bootstrap.nu) — step **4**, *after*
the existing preconditioning/service-mesh patches and *before* `git-registry push`. That ordering is
mandatory: everything must be committed to the private repo when `main init gitops` later applies the
root `main.yaml` app-of-apps, or Argo won't see it.

```nu
# cli/kube-tools/bootstrap.nu — step 4, before the push
let broker_subnets = (infra output --cloud-provider=$cloud_provider --output-name=public_subnet_ids | from json | str join ",")
let broker_domain  = ($env.domain_name | str trim -c '"')
app-of-apps register-agents               # kagent trio + agentic CRs
app-of-apps register-session-broker       # the broker bootstrap Application
broker-exposure render --domain=$broker_domain --subnets=$broker_subnets   # shared-ALB Ingress + Istio routes
broker-keycloak-config render --domain=$broker_domain                      # tenant Keycloak/broker host ConfigMaps
```

`main init`'s flow comment ([cli/enterpriseclaw](../../../../cli/enterpriseclaw) step 3) notes this.

## The three modules

### `cli/gitops/app-of-apps.nu` — app-of-apps wiring

Generates three Argo CD definition files into the freshly-cloned private repo (`gitops-config/`) and
registers them idempotently in its root `kustomization.yaml`:

| File written | Kind | Points at | Notes |
|---|---|---|---|
| `agents.yaml` | ApplicationSet `agents` | PUBLIC repo `gitops/helm/agents/*` | kagent-trio **installer**; sync-wave `1` |
| `agentic.yaml` | ApplicationSet `agentic` | PUBLIC repo `gitops/agentic/*` | the **CRs** (Agents/MCPs/gateways); sync-wave `2`; ns `kagent` |
| `session-broker.yaml` | Application **`session-broker-bootstrap`** | **broker repo** `gitops` + `directory.include: bootstrap.yaml` | applies ONLY the broker's `session-broker-platform` ApplicationSet. **Name is `session-broker-bootstrap`, NOT `session-broker`** — the AppSet generates a child named `session-broker`; sharing the name = one Argo object, two owners → `resources-finalizer` deadlock that cascade-prunes keycloak/redis/dapr (fixed 2026-06-29). |

- **Pure generators** (`app-of-apps agents-appset` / `agentic-appset` / `session-broker-app` /
  `merge-resources`) return records — unit-tested, no IO.
- **IO orchestrators** (`register-agents` / `register-session-broker` / `ensure-resources`) serialize with
  `to yaml | save` and idempotently merge the kustomization (`uniq`, order-preserving — safe across the
  `rm -rf gitops-config/` + re-clone that init does every run).
- The CLI is the **single source of truth** for the prod app-of-apps wiring — there is intentionally **no
  redundant public `gitops/agents-appset.yaml`** to drift. (`gitops/agentic-appset.yaml` and
  `gitops/dry-run/agents-appset.yaml` remain as standalone/dry-run artifacts.)

### `cli/gitops/broker-exposure.nu` — Istio internet exposure

Because keycloak ships `ingress.enabled: false` and the broker ships a placeholder-host ingress, neither is
reachable as-installed. EnterpriseClaw owns Istio, so it provides the exposure: `broker-exposure render`
writes **fully-resolved** manifests (real host from `$env.domain_name`) into
`gitops-config/config/session-broker/`, which the existing **`configs` ApplicationSet (globs `config/*`)
auto-onboards** as `config-session-broker`.

| File | Kind | Routes |
|---|---|---|
| `ingress.yaml` | AWS ALB `Ingress` `session-broker-istio-ingress` (ns `istio-ingress`) | admits `auth.<domain>` (`/`) + `broker.<domain>` (`/auth/callback`) → `istio-ingress` svc :80, on the **shared ALB** |
| `gateway.yaml` | Istio `Gateway` `session-broker-gateway` (ns `istio-ingress`, selector `istio: ingress`, :80 HTTP) | hosts `auth.<domain>` + `broker.<domain>` |
| `virtual-service-keycloak.yaml` | `VirtualService` (ns `keycloak`) | `auth.<domain>` `/` → `keycloak.keycloak.svc.cluster.local:80` |
| `virtual-service-broker.yaml` | `VirtualService` (ns `session-broker`) | `broker.<domain>` **`/auth/callback`** → `session-broker.session-broker.svc.cluster.local:80` |
| `kustomization.yaml` | — | lists the four |

- The broker VS is **scoped to `/auth/callback`** (minimal external surface — `/identity/resolve` and
  `/auth/login/start` are internal-only). Host subdomains are configurable (`--auth-label`, `--broker-label`).
- Resources carry **explicit namespaces**, which Argo honors over the app's default destination namespace —
  the same pattern the argo-events `config-security`/`config-istio` routing already uses.
- Mirrors the proven argo-events exposure shape: TLS terminates at the ALB; `istio-ingress` speaks HTTP behind it.

## Shared ALB (DONE — implemented 2026-06-26)

"Reuse the existing internet-facing ALB" is implemented via a single AWS LB Controller **IngressGroup**:
- A shared group name constant — [`alb shared-group`](../../../../cli/utils/generals.nu) = `enterpriseclaw`.
- The per-tenant Istio Ingress patch
  ([service-mesh/patches.nu](../../../../cli/kube-tools/service-mesh/patches.nu)) now stamps
  `alb.ingress.kubernetes.io/group.name` on **every** kubetool Ingress (argocd / argo-workflows /
  argo-events), folding the previously-separate per-tool ALBs onto one.
- The broker/Keycloak Ingress (`broker-exposure ingress`) carries the **same** group name + the public
  subnets (passed from `infra output public_subnet_ids` in the bootstrap step) + an external-dns
  annotation for both hosts, so it rides that same ALB. Host-based routing forwards each host to the
  `istio-ingress` service; the Istio Gateway/VS take it from there.
- On a fresh `init` there is no ALB to disrupt (everything is created with the group from the start). On a
  re-run against a live cluster the controller reconciles the existing per-tool ALBs into the shared one
  (some churn) — acceptable for the ephemeral init/destroy flow.

### `cli/gitops/broker-keycloak-config.nu` — tenant Keycloak/broker hostnames **+ secret wiring**

The tenant external host (`auth.<domain>` / `broker.<domain>`) is end-user config the broker repo cannot
know. `broker-keycloak-config render` resolves it from `$env.domain_name` and writes **two `keycloak-hostnames`
ConfigMaps PLUS five ExternalSecrets** into the private repo's `config/session-broker-keycloak/` (its own
kustomization → its own `config-session-broker-keycloak` Argo app, auto-onboarded by the `configs`
ApplicationSet). The ConfigMaps:

| File | ConfigMap (ns) | Keys |
|---|---|---|
| `keycloak-hostnames-cm.yaml` | `keycloak-hostnames` (ns `keycloak`) | `KC_HOSTNAME_URL`, `KC_HOSTNAME_ADMIN_URL` = `https://auth.<domain>`; `BROKER_EXTERNAL_URL` = `https://broker.<domain>` |
| `broker-hostnames-cm.yaml` | `keycloak-hostnames` (ns `session-broker`) | `KEYCLOAK_ISSUER_URL` = `https://auth.<domain>/realms/<realm>`; `KEYCLOAK_REDIRECT_URI` = `https://broker.<domain>/auth/callback` |

- Pure generators (`keycloak-cm` / `broker-cm` / `kustomization`) are unit-tested; `render` is the IO.
- **Labels/realm are configurable** (`--auth-label` / `--broker-label` / `--realm`, default `auth`/`broker`/`enterpriseclaw`)
  and **MUST stay aligned with `broker-exposure`** — the issuer host is the host the ALB+Istio admit.
- Host values are **non-secret**, so a ConfigMap (not the `keycloak-realm-secrets` Secret) is the
  vehicle; the broker reads them with `extraEnvVarsCM`.

## Secret wiring (built 2026-06-29) — EnterpriseClaw fills the charts' `existingSecret`s

The broker/Keycloak/Redis charts declare `existingSecret` names + realm `$(env:…)` keys but don't supply the
values. EnterpriseClaw provisions them through **two layers**:

**1. The SM source — `infrastructure/aws/secrets-manager/`.** The module now *creates* (not just reads) one SM
secret **`keycloak-internal`** via `random_password` (7 keys: `admin-password`, `postgres-password`, `password`,
`session-broker-client-secret`, `kagent-controller-client-secret`, `alice-password`, `redis-password`),
`recovery_window_in_days = 0` so destroy hard-deletes it. Externally-managed secrets stay read-referenced via
`secrets_registries` in `cli/infra/vars.nu` (now includes `google-idp` + `github-readonly-token`). The read
policy is **scoped to EXACT ARNs**, so any SM key an ExternalSecret reads must be in `secrets_registries` or
created by the module. **`terraform_user` therefore needs SM `CreateSecret`/`PutSecretValue`/`TagResource`/
`DeleteSecret`** — it only read before; a read-only identity fails the apply on `aws_secretsmanager_secret_version`.

**2. The ExternalSecrets — `broker-keycloak-config.nu` generators** (all `git-creds-secretstore` ClusterSecretStore,
`spec.data` with `remoteRef.key`+`property`):

| File / target Secret (ns) | Keys ← SM source |
|---|---|
| `external-secret-keycloak-admin.yaml` → `keycloak-admin-secret` (keycloak) | `admin-password` ← `keycloak-internal` |
| `external-secret-keycloak-postgresql.yaml` → `keycloak-postgresql-secret` (keycloak) | `password`, `postgres-password` ← `keycloak-internal` |
| `external-secret-keycloak-realm.yaml` → `keycloak-realm-secrets` (keycloak) | `SESSION_BROKER_CLIENT_SECRET`/`KAGENT_CONTROLLER_CLIENT_SECRET`/`ALICE_PASSWORD` ← `keycloak-internal`; **`GOOGLE_CLIENT_SECRET` ← `google-idp`/`CLIENT_SECRET`** |
| `external-secret-session-broker.yaml` → `session-broker-secret` (session-broker) | `keycloak-client-secret` ← `keycloak-internal`/`session-broker-client-secret` |
| `external-secret-redis.yaml` → `redis-secret` (redis) | `redis-password` ← `keycloak-internal` |

- **CRITICAL shared secret:** `session-broker-secret/keycloak-client-secret` and
  `keycloak-realm-secrets/SESSION_BROKER_CLIENT_SECRET` source the **SAME** `keycloak-internal`/`session-broker-client-secret`
  property — the broker and Keycloak's `session-broker` client must agree on the OAuth secret. One SM property feeds
  both so they can't drift. (Same idea for `KAGENT_CONTROLLER_CLIENT_SECRET` ↔ the kagent discovery token.)
- The realm-import Job (`keycloak-config-cli`, a Helm hook) consumes `keycloak-realm-secrets` and runs once it exists;
  its success (realm `enterpriseclaw` serving discovery) confirms all four realm secrets were consumed correctly.
- The overlay legitimately **spans namespaces** (keycloak / session-broker / redis) — Argo honors each manifest's
  explicit `metadata.namespace`. These ExternalSecrets are domain-independent (framework constants), generated into
  the private overlay alongside the tenant hostname CMs; on the eventual OSS split they could move to the public repo.
- **Related fix:** the kagent `github-readonly` ExternalSecret (`gitops/agentic/mcps/`) reads `github-readonly-token`/`GH_TOKEN`
  → target key `GITHUB_PERSONAL_ACCESS_TOKEN` (it had been pointing at a non-existent SM key `github-readonly-creds`).

## STILL OPEN — the BROKER-SIDE change the user applies (chosen: "EC side only; you do broker")

Why a broker change is unavoidable: the realm's `redirectUris`/`webOrigins` live **inside the monolithic
`keycloakConfigCli.configuration` Helm string**, which the private repo cannot sub-string patch — without
the right `redirect_uri`, Keycloak rejects the callback and login fails. EnterpriseClaw now supplies the
tenant host (the ConfigMaps above); the **Session-Broker repo** must consume them (the full contract is the
header of [broker-keycloak-config.nu](../../../../cli/gitops/broker-keycloak-config.nu)).

> **Ready-to-paste handoff:** [`broker-side-change.prompt.md`](broker-side-change.prompt.md) is a
> self-contained prompt to run inside the Session-Broker repo that implements exactly the change below.

Summary of that change:

1. `gitops/keycloak/values.yaml` — `extraEnvVarsCM: keycloak-hostnames` on the workload (+ run Keycloak in
   proxy/edge so `KC_HOSTNAME_URL` drives the external issuer) and on `keycloakConfigCli`; change the
   `session-broker` client `redirectUris` → `$(env:BROKER_EXTERNAL_URL)/auth/callback` and `webOrigins` →
   `$(env:BROKER_EXTERNAL_URL)` (its `IMPORT_VARSUBSTITUTION_ENABLED: "true"` already enables `$(env:…)`).
2. `gitops/session-broker` (the overlay `bootstrap.yaml` installs) — feed the Deployment from the CM
   (`envFrom: [{configMapRef: {name: keycloak-hostnames}}]`) and **remove** the hardcoded
   `KEYCLOAK_ISSUER_URL`/`KEYCLOAK_REDIRECT_URI` env (explicit env wins over envFrom); also point bootstrap
   at a cloud overlay, not the localhost `dev` one.

Minor: the two CMs target the `keycloak` / `session-broker` namespaces, which the broker's apps create; if a
CM syncs before its namespace exists, Argo retries (eventually consistent) — fine for the ephemeral flow.

## Tests

[`cli/tests/`](../../../../cli/tests/) — dependency-free `std assert` harness, run with **`nu tests/run.nu`** from
`cli/` inside Devbox. Covers every pure generator, the idempotent kustomization-merge, the `register-*` IO
orchestrators, and the exposure `render` (against a seeded temp private-repo). **Cluster-free** by design —
the unit-test approach chosen for this work. See [cli/tests/README.md](../../../../cli/tests/README.md).