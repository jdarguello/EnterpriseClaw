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
app-of-apps register-agents          # kagent trio + agentic CRs
app-of-apps register-session-broker  # the broker bootstrap Application
broker-exposure render --domain=($env.domain_name | str trim -c '"')
```

`main init`'s flow comment ([cli/enterpriseclaw](../../../../cli/enterpriseclaw) step 3) notes this.

## The two modules

### `cli/gitops/app-of-apps.nu` — app-of-apps wiring

Generates three Argo CD definition files into the freshly-cloned private repo (`gitops-config/`) and
registers them idempotently in its root `kustomization.yaml`:

| File written | Kind | Points at | Notes |
|---|---|---|---|
| `agents.yaml` | ApplicationSet `agents` | PUBLIC repo `gitops/helm/agents/*` | kagent-trio **installer**; sync-wave `1` |
| `agentic.yaml` | ApplicationSet `agentic` | PUBLIC repo `gitops/agentic/*` | the **CRs** (Agents/MCPs/gateways); sync-wave `2`; ns `kagent` |
| `session-broker.yaml` | Application `session-broker` | **broker repo** `gitops` + `directory.include: bootstrap.yaml` | applies ONLY the broker's `session-broker-platform` ApplicationSet |

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
| `gateway.yaml` | Istio `Gateway` `session-broker-gateway` (ns `istio-ingress`, selector `istio: ingress`, :80 HTTP) | hosts `auth.<domain>` + `broker.<domain>` |
| `virtual-service-keycloak.yaml` | `VirtualService` (ns `keycloak`) | `auth.<domain>` `/` → `keycloak.keycloak.svc.cluster.local:80` |
| `virtual-service-broker.yaml` | `VirtualService` (ns `session-broker`) | `broker.<domain>` **`/auth/callback`** → `session-broker.session-broker.svc.cluster.local:80` |
| `kustomization.yaml` | — | lists the three |

- The broker VS is **scoped to `/auth/callback`** (minimal external surface — `/identity/resolve` and
  `/auth/login/start` are internal-only). Host subdomains are configurable (`--auth-label`, `--broker-label`).
- Resources carry **explicit namespaces**, which Argo honors over the app's default destination namespace —
  the same pattern the argo-events `config-security`/`config-istio` routing already uses.
- Mirrors the proven argo-events exposure shape: TLS terminates at the ALB; `istio-ingress` speaks HTTP behind it.

## STILL OPEN (not done — needs decisions)

1. **ALB host-admission ("reuse the ALB" literally).** The Istio routes above are **inert until the existing
   internet-facing `istio-ingress` ALB is told to admit `auth.<domain>` + `broker.<domain>`** — i.e. a shared
   ALB via `alb.ingress.kubernetes.io/group.name` on both a new Ingress *and* the existing argo-events Ingress,
   or extra host rules on it. This **touches the proven GitHub-webhook ALB path** (brief ALB re-creation), so it
   was deliberately left for an explicit decision. The current single internet-facing ALB is
   `argo-events-istio-ingress` (scheme `internet-facing`, public subnets injected by the private-repo
   `config/istio/argo-events/ingress-patch.yaml`).
2. **`KC_HOSTNAME` pinning** — a broker-repo change (see SKILL.md gotcha 2). Cannot be done from here.

## Tests

[`cli/tests/`](../../../../cli/tests/) — dependency-free `std assert` harness, run with **`nu tests/run.nu`** from
`cli/` inside Devbox. Covers every pure generator, the idempotent kustomization-merge, the `register-*` IO
orchestrators, and the exposure `render` (against a seeded temp private-repo). **Cluster-free** by design —
the unit-test approach chosen for this work. See [cli/tests/README.md](../../../../cli/tests/README.md).