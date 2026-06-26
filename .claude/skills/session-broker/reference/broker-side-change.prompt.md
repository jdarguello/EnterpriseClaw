# Handoff prompt — Session-Broker repo: consume EnterpriseClaw's tenant-hostname ConfigMaps

Paste the block below into a Claude Code session running **inside the `github.com/jdarguello/Session-Broker`
repo**. It is self-contained — it does not assume access to the EnterpriseClaw repo or this conversation.

> Context for why this exists: EnterpriseClaw's `enterpriseclaw init` now writes the tenant's external
> hostnames into the cluster as ConfigMaps (the host is end-user config, `https://auth.<domain>` /
> `https://broker.<domain>`, that this repo can't know at author time). This repo must **consume** them.
> The reason EnterpriseClaw can't just patch this repo's manifests from outside: the realm's
> `redirectUris`/`webOrigins` are a sub-string inside one monolithic Helm-rendered string in
> `gitops/keycloak/values.yaml`, which no external overlay can reach — so the host must enter through a
> `$(env:…)` substitution seam, which this repo already half-supports (`IMPORT_VARSUBSTITUTION_ENABLED: "true"`).

---

## TASK

You are working in the **Session-Broker** GitOps repo. A separate platform (EnterpriseClaw) installs this
repo's `gitops/bootstrap.yaml` ApplicationSet and, **before** it does, creates a ConfigMap named
`keycloak-hostnames` in **two** namespaces, carrying the tenant's real external hostnames. Wire this repo's
Keycloak + session-broker manifests to consume those ConfigMaps so that issued tokens carry the correct
external `iss` and the OAuth callback is accepted. Do **not** hardcode any tenant domain — read everything
from the ConfigMaps below.

### The contract (provided by EnterpriseClaw — do NOT create these; just consume them)

ConfigMap `keycloak-hostnames` in namespace **`keycloak`**:

| Key | Example value |
|---|---|
| `KC_HOSTNAME_URL` | `https://auth.<domain>` |
| `KC_HOSTNAME_ADMIN_URL` | `https://auth.<domain>` |
| `BROKER_EXTERNAL_URL` | `https://broker.<domain>` |

ConfigMap `keycloak-hostnames` in namespace **`session-broker`**:

| Key | Example value |
|---|---|
| `KEYCLOAK_ISSUER_URL` | `https://auth.<domain>/realms/enterpriseclaw` |
| `KEYCLOAK_REDIRECT_URI` | `https://broker.<domain>/auth/callback` |

(Same ConfigMap name in both namespaces; `<domain>` and the `enterpriseclaw` realm are filled in by
EnterpriseClaw at deploy time.)

### Changes to make

**1. `gitops/keycloak/values.yaml`**
- On the **main Keycloak workload**: add `extraEnvVarsCM: keycloak-hostnames` so `KC_HOSTNAME_URL` /
  `KC_HOSTNAME_ADMIN_URL` become env vars Keycloak reads natively.
- Make Keycloak honor that external hostname behind the TLS-terminating ALB so the issuer scheme is
  **https** (the platform terminates TLS at the ALB and speaks HTTP to Keycloak). Determine and set the
  correct Keycloak-22 / Bitnami-22.2.3 flags for this — e.g. enable proxy/edge handling so `X-Forwarded-*`
  is trusted and `KC_HOSTNAME_URL` drives the front-end/issuer URL. **Verify** the result: a token's `iss`
  and `https://auth.<domain>/realms/enterpriseclaw/.well-known/openid-configuration` → `"issuer"` must both
  equal `https://auth.<domain>/realms/enterpriseclaw`. (This is the one genuinely Keycloak-deployment-specific
  decision — confirm it against the chart's options, don't guess.)
- On the **`keycloakConfigCli`** block: add `extraEnvVarsCM: keycloak-hostnames` so `BROKER_EXTERNAL_URL`
  is present in the import Job's env for `$(env:…)` substitution.
- In the realm's **`session-broker` client**, replace the hardcoded host:
  - `redirectUris`: `["$(env:BROKER_EXTERNAL_URL)/auth/callback", "http://localhost:8000/auth/callback"]`
  - `webOrigins`: `["$(env:BROKER_EXTERNAL_URL)"]`
  (Keep the localhost entry so the local SSH-tunnel dev flow still works.)

**2. The session-broker overlay that `gitops/bootstrap.yaml` installs**
- `bootstrap.yaml` currently points the `session-broker` element at `gitops/session-broker/overlays/dev`
  (localhost). For a cloud deploy that's wrong. Either repurpose `overlays/prod` or add an `overlays/aws`,
  and point `bootstrap.yaml`'s `session-broker` element `path` at it.
- In that overlay, make the Deployment read the front-channel URLs from the ConfigMap:
  add `envFrom: [{ configMapRef: { name: keycloak-hostnames } }]` to the container, and **remove** the
  explicit `KEYCLOAK_ISSUER_URL` / `KEYCLOAK_REDIRECT_URI` env entries (an explicit `env` value wins over
  `envFrom`, so they must be gone for the ConfigMap to take effect).
- Leave `KEYCLOAK_TOKEN_URL` (the in-cluster back-channel `code→token` endpoint) **unchanged** — it is
  intentionally the ClusterIP, not an external host.

### Acceptance criteria

- `kubectl get cm keycloak-hostnames -n keycloak` and `-n session-broker` both exist (created by
  EnterpriseClaw; this repo only references them).
- The Keycloak discovery `issuer` = `https://auth.<domain>/realms/enterpriseclaw` (https, external host).
- The realm's `session-broker` client lists `https://broker.<domain>/auth/callback` in `redirectUris`.
- The session-broker pod's env shows `KEYCLOAK_ISSUER_URL` / `KEYCLOAK_REDIRECT_URI` = the tenant https
  URLs (not the `*.session-broker.example.com` placeholders, not localhost).
- End-to-end: `/auth/login/start` → Keycloak `/authorize` → login → redirect to
  `https://broker.<domain>/auth/callback` succeeds with **no "Invalid redirect_uri"**.

### Notes / guardrails

- Do not commit any tenant domain, secret, or plaintext credential. Hosts come only from the ConfigMaps;
  secrets stay in the existing out-of-band `keycloak-realm-secrets` / `session-broker-secret`.
- Keep the change **additive** — don't disturb the existing realm roles/groups/clients or the
  `keycloak-config-cli` no-delete import mode.
- The ConfigMaps may briefly not exist yet when Argo first syncs (their namespaces are created by this
  repo's apps with `CreateNamespace=true`); Argo retries, so this is eventually consistent — no action
  needed on this repo's side beyond referencing them.
