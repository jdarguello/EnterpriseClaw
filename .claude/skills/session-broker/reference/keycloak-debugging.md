# Debugging Keycloak / the Google-federation login path

How to diagnose the login wall when a user gets an error after clicking the Keycloak URL. Verified live on the AWS sandbox **2026-07-01** (Keycloak = **Bitnami** image, realm `enterpriseclaw`, IdP alias `google`, host `auth.enterprise-claw.io`).

## The login chain (where each error surfaces)

```
Slack login wall → broker /auth/login/start → Keycloak /authorize (realm enterpriseclaw)
  → user clicks "Sign in with Google"
  → Keycloak redirects to Google with redirect_uri = https://auth.<domain>/realms/enterpriseclaw/broker/google/endpoint
  → Google consent → back to that broker endpoint  → Keycloak code→token with Google  → applies realm IdP mappers
  → back to broker /auth/callback → broker code→token → caches token in Redis → done
```

## Failure mode (a): Google `Error 400: redirect_uri_mismatch`

Reaching Google's screen means the whole broker→Keycloak→Google chain works; the ONLY problem is that Google doesn't recognize Keycloak's callback URL. Google requires a **character-for-character** match.

- **Keycloak always sends:** `https://auth.<domain>/realms/<realm>/broker/<idp-alias>/endpoint`
  (sandbox: `https://auth.enterprise-claw.io/realms/enterpriseclaw/broker/google/endpoint`).
- **Fix (Google Cloud Console → APIs & Services → Credentials → the OAuth 2.0 Client whose creds feed the `google-idp` SM secret → Authorized redirect URIs):** add that exact URL. No trailing slash, `https`, no port. The bare `https://auth.<domain>/` (root) and `http://localhost:8080/realms/…/broker/google/endpoint` (local dev) do **not** satisfy it.
- **Ground truth:** on the error page, "detalles del error / error details" prints the literal `redirect_uri=…` Google received — register that verbatim.

## Failure mode (b): Keycloak "We are sorry… Unexpected error when authenticating with identity provider"

This is **past Google** — Google auth + `code→token` succeeded, and Keycloak crashed applying the realm's IdP mappers. It is a **realm config bug, not creds/network.** The server log shows:

```
ERROR AbstractOAuth2IdentityProvider  Failed to make identity provider oauth callback:
java.lang.NullPointerException: Cannot invoke
"IdentityProviderMapper.preprocessFederatedIdentity(...)" because "target" is null
  at IdentityBrokerService.authenticated(IdentityBrokerService.java:546)
```

`target is null` = the realm defines an IdP mapper whose `identityProviderMapper` **type id doesn't resolve to a registered mapper provider** → `getProviderFactory()` returns null → NPE.

- **Root cause seen:** the `default-engineering-group` Google mapper used `identityProviderMapper: "hardcoded-group-idp-mapper"` — **not a valid id in this build.** The correct id for an OIDC/Google IdP is **`oidc-hardcoded-group-idp-mapper`** (the `oidc-` prefix matters). Confirm the registered ids with `kcadm get serverinfo` (there's `oidc-hardcoded-group-idp-mapper` and `hardcoded-attribute-idp-mapper`, but no bare `hardcoded-group-idp-mapper`).
- **Also verify** the mapper's target group (`config.group: /engineering`) exists in the realm — `kcadm get groups -r enterpriseclaw`.

### DURABLE fix vs. live patch

The realm is imported by a `keycloak-config-cli` sync-hook Job from the **broker repo** file `gitops/keycloak/values.yaml` (`identityProviderMappers:` block). **A live kcadm patch is reverted by the next broker app re-sync** unless you also fix that source file. Change it there (`hardcoded-group-idp-mapper` → `oidc-hardcoded-group-idp-mapper`), commit, push — then source and live agree and re-syncs are safe.

## The reusable recipe: driving `kcadm` on the Bitnami Keycloak pod

Non-obvious specifics that cost time on the Bitnami image:
- `kcadm.sh` lives at **`/opt/bitnami/keycloak/bin/kcadm.sh`** (NOT `/opt/keycloak/bin/`).
- Admin env vars in-pod: **`KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD`** (reference them in-pod so the password is never handled/printed outside the container).
- `$HOME` is **read-only** → pass **`--config /tmp/kcadm.config`** or `config credentials` fails to write its state.
- Redact secrets: `kcadm get identity-provider/instances/google` includes `clientSecret` — pipe through `grep -v clientSecret`.

```bash
# from cli/ (devbox provides kubectl):  eval "$(devbox shellenv)"
kubectl exec -n keycloak keycloak-0 -- bash -c '
  KCADM=/opt/bitnami/keycloak/bin/kcadm.sh; CFG=/tmp/kcadm.config
  $KCADM config credentials --config $CFG --server http://localhost:8080 --realm master \
    --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD"
  # inspect the Google IdP mappers (the usual culprit):
  $KCADM get identity-provider/instances/google/mappers -r enterpriseclaw --config $CFG
  # list valid mapper provider ids:
  $KCADM get serverinfo --config $CFG | grep -iE "idp-mapper|hardcoded"
'
```

Live-fix a broken mapper (delete + recreate — the `identityProviderMapper` type is set at creation, not mutable on update):

```bash
$KCADM delete identity-provider/instances/google/mappers/<id> -r enterpriseclaw --config $CFG
$KCADM create identity-provider/instances/google/mappers -r enterpriseclaw --config $CFG \
  -s name=default-engineering-group \
  -s identityProviderAlias=google \
  -s identityProviderMapper=oidc-hardcoded-group-idp-mapper \
  -s 'config."syncMode"=INHERIT' \
  -s 'config.group=/engineering'
```

## Other Keycloak log lines you can ignore

- `error="ssl_required"` LOGIN_ERRORs from random IPs = internet noise hitting the public host over plain HTTP.
- `error="cookie_not_found"` = a stale/abandoned login tab; not your failure.
- First-boot `/realms/master` connection-refused for ~90s is normal Quarkus augmentation, not a crash (see the [keycloak-slow-boot memory]).

## Pushing the durable fix to the broker repo

The broker repo's embedded remote PAT may be dead (same failure as the EnterpriseClaw auto-sync hook). Push with the valid `GH_TOKEN` from `cli/.env`, sanitizing output:
`git push "https://x-access-token:${GH_TOKEN}@github.com/jdarguello/Session-Broker.git" main`
(extract with `sed -n 's/^export GH_TOKEN=//p' .env | tr -d '"\r'` — BSD sed has no `\s`, and a stray CR in the token yields curl's "Malformed input to a URL function").
