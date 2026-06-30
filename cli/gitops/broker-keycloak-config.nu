# broker-keycloak-config.nu — EnterpriseClaw supplies the TENANT external hostnames for Keycloak +
# the Session-Broker, from the private repo. The host (auth.<domain> / broker.<domain>) is end-user
# config the broker repo cannot know, so the CLI resolves it from $env.domain_name and writes it into
# the private repo as ConfigMaps. The broker manifests CONSUME these via a parameter seam (see the
# "BROKER-SIDE CONTRACT" below) — this is the part EnterpriseClaw owns ("configure it from the private
# repo"); the broker just references the variables.
#
# Why ConfigMaps (not a Kustomize/Helm patch from here): the realm's redirectUris/webOrigins live
# INSIDE one monolithic Helm-rendered string in the broker's keycloak values, which cannot be
# sub-string patched from another repo. The broker already runs keycloak-config-cli with
# IMPORT_VARSUBSTITUTION_ENABLED=true, so the clean seam is `$(env:VAR)` substitution fed from a
# ConfigMap EnterpriseClaw populates — host values are non-secret, so a ConfigMap (not a Secret) fits.
#
# ===========================================================================================
# BROKER-SIDE CONTRACT (the change the Session-Broker repo owner applies — NOT done from here)
# ===========================================================================================
# EnterpriseClaw writes ONE ConfigMap named `keycloak-hostnames` into TWO namespaces:
#
#   ns keycloak        (consumed by the Keycloak chart + its config-cli Job)
#     KC_HOSTNAME_URL        = https://auth.<domain>
#     KC_HOSTNAME_ADMIN_URL  = https://auth.<domain>
#     BROKER_EXTERNAL_URL    = https://broker.<domain>
#
#   ns session-broker  (consumed by the broker Deployment)
#     KEYCLOAK_ISSUER_URL    = https://auth.<domain>/realms/<realm>
#     KEYCLOAK_REDIRECT_URI  = https://broker.<domain>/auth/callback
#
# The broker repo then, to consume them:
#   1. gitops/keycloak/values.yaml
#        - main workload:   extraEnvVarsCM: keycloak-hostnames   (+ run Keycloak in proxy/edge mode so
#                           KC_HOSTNAME_URL drives the external issuer; exact KC flags are the broker's call)
#        - keycloakConfigCli: extraEnvVarsCM: keycloak-hostnames (so BROKER_EXTERNAL_URL is in the Job env)
#        - realm session-broker client:
#            redirectUris: ["$(env:BROKER_EXTERNAL_URL)/auth/callback", "http://localhost:8000/auth/callback"]
#            webOrigins:   ["$(env:BROKER_EXTERNAL_URL)"]
#   2. gitops/session-broker (the overlay bootstrap.yaml installs):
#        - feed the Deployment from the CM (envFrom: [{configMapRef: {name: keycloak-hostnames}}]) and
#          REMOVE the hardcoded KEYCLOAK_ISSUER_URL / KEYCLOAK_REDIRECT_URI env (explicit env wins over
#          envFrom), so the tenant values take effect. (Also point bootstrap at a cloud overlay, not the
#          localhost `dev` one.)
source ../utils/generals.nu

# ---------------------------------------------------------------------------
# Pure generators — return the ConfigMap as a Nushell record.
# ---------------------------------------------------------------------------

# Host config the KEYCLOAK namespace consumes (frontend/issuer host + the broker's external URL the
# realm's redirectUris/webOrigins substitute in).
def "broker-keycloak-config keycloak-cm" [
    --auth-url:   string            # https://auth.<domain>
    --broker-url: string            # https://broker.<domain>
] {
    {
        apiVersion: "v1"
        kind: "ConfigMap"
        metadata: { name: "keycloak-hostnames", namespace: "keycloak" }
        data: {
            KC_HOSTNAME_URL: $auth_url
            KC_HOSTNAME_ADMIN_URL: $auth_url
            BROKER_EXTERNAL_URL: $broker_url
        }
    }
}

# Host config the SESSION-BROKER namespace consumes (the broker Deployment's front-channel OAuth URLs).
def "broker-keycloak-config broker-cm" [
    --issuer-url:   string          # https://auth.<domain>/realms/<realm>
    --redirect-uri: string          # https://broker.<domain>/auth/callback
] {
    {
        apiVersion: "v1"
        kind: "ConfigMap"
        metadata: { name: "keycloak-hostnames", namespace: "session-broker" }
        data: {
            KEYCLOAK_ISSUER_URL: $issuer_url
            KEYCLOAK_REDIRECT_URI: $redirect_uri
        }
    }
}

# ---------------------------------------------------------------------------
# Pure generators — ExternalSecrets that wire the Keycloak / Session-Broker
# stack's secrets from AWS Secrets Manager into the cluster via External-Secrets.
#
# All four reference the same ClusterSecretStore (git-creds-secretstore) the rest
# of the repo uses, and pull SPECIFIC JSON properties out of two SM entries:
#   - keycloak-internal : the Keycloak/broker internal secrets (admin/db/client/realm)
#   - google-idp        : the Google federated-IdP client credentials
# The SM key names + namespaces are framework constants, so these defs take no
# tenant args (the host values are the only tenant-resolved part of this overlay).
# spec.data is used (NOT dataFrom) because we map named JSON properties → secretKeys.
# ---------------------------------------------------------------------------

# Keycloak bootstrap admin password (ns keycloak).
def "broker-keycloak-config es-keycloak-admin" [] {
    {
        apiVersion: "external-secrets.io/v1beta1"
        kind: "ExternalSecret"
        metadata: { name: "keycloak-admin-secret", namespace: "keycloak" }
        spec: {
            refreshInterval: "1h"
            secretStoreRef: { name: "git-creds-secretstore", kind: "ClusterSecretStore" }
            target: { name: "keycloak-admin-secret", creationPolicy: "Owner" }
            data: [
                { secretKey: "admin-password", remoteRef: { key: "keycloak-internal", property: "admin-password" } }
            ]
        }
    }
}

# Keycloak's PostgreSQL credentials (ns keycloak).
def "broker-keycloak-config es-keycloak-postgresql" [] {
    {
        apiVersion: "external-secrets.io/v1beta1"
        kind: "ExternalSecret"
        metadata: { name: "keycloak-postgresql-secret", namespace: "keycloak" }
        spec: {
            refreshInterval: "1h"
            secretStoreRef: { name: "git-creds-secretstore", kind: "ClusterSecretStore" }
            target: { name: "keycloak-postgresql-secret", creationPolicy: "Owner" }
            data: [
                { secretKey: "password", remoteRef: { key: "keycloak-internal", property: "password" } }
                { secretKey: "postgres-password", remoteRef: { key: "keycloak-internal", property: "postgres-password" } }
            ]
        }
    }
}

# Realm-import secrets the keycloak-config-cli Job consumes (ns keycloak):
# the OAuth client secrets, the seeded test user's password, and the Google IdP secret.
# NOTE: SESSION_BROKER_CLIENT_SECRET sources keycloak-internal/session-broker-client-secret —
# the SAME SM property the session-broker side reads, so the two sides AGREE on the client secret.
def "broker-keycloak-config es-keycloak-realm" [] {
    {
        apiVersion: "external-secrets.io/v1beta1"
        kind: "ExternalSecret"
        metadata: { name: "keycloak-realm-secrets", namespace: "keycloak" }
        spec: {
            refreshInterval: "1h"
            secretStoreRef: { name: "git-creds-secretstore", kind: "ClusterSecretStore" }
            target: { name: "keycloak-realm-secrets", creationPolicy: "Owner" }
            data: [
                { secretKey: "SESSION_BROKER_CLIENT_SECRET", remoteRef: { key: "keycloak-internal", property: "session-broker-client-secret" } }
                { secretKey: "KAGENT_CONTROLLER_CLIENT_SECRET", remoteRef: { key: "keycloak-internal", property: "kagent-controller-client-secret" } }
                { secretKey: "ALICE_PASSWORD", remoteRef: { key: "keycloak-internal", property: "alice-password" } }
                { secretKey: "GOOGLE_CLIENT_SECRET", remoteRef: { key: "google-idp", property: "CLIENT_SECRET" } }
            ]
        }
    }
}

# The Session-Broker's view of the shared OAuth client secret (ns session-broker).
# MUST source the SAME SM property as es-keycloak-realm's SESSION_BROKER_CLIENT_SECRET
# (keycloak-internal/session-broker-client-secret) so the broker and Keycloak agree.
def "broker-keycloak-config es-session-broker" [] {
    {
        apiVersion: "external-secrets.io/v1beta1"
        kind: "ExternalSecret"
        metadata: { name: "session-broker-secret", namespace: "session-broker" }
        spec: {
            refreshInterval: "1h"
            secretStoreRef: { name: "git-creds-secretstore", kind: "ClusterSecretStore" }
            target: { name: "session-broker-secret", creationPolicy: "Owner" }
            data: [
                { secretKey: "keycloak-client-secret", remoteRef: { key: "keycloak-internal", property: "session-broker-client-secret" } }
            ]
        }
    }
}

# Redis (Session-Broker cache) auth secret. The SAME redis-password (SM
# keycloak-internal/redis-password) is needed in TWO namespaces, so this is
# rendered once per namespace (both sourcing the one SM property, so they agree):
#   - ns redis          : the broker repo's redis chart's auth.existingSecret
#                         (existingSecretPasswordKey=redis-password) for the server.
#   - ns session-broker : the Dapr `redis` state-store Component resolves its
#                         secretKeyRef in ITS OWN namespace, so daprd needs
#                         redis-secret here too — without it the sidecar fails
#                         component load fatally and crashloops.
def "broker-keycloak-config es-redis" [--namespace = "redis"] {
    {
        apiVersion: "external-secrets.io/v1beta1"
        kind: "ExternalSecret"
        metadata: { name: "redis-secret", namespace: $namespace }
        spec: {
            refreshInterval: "1h"
            secretStoreRef: { name: "git-creds-secretstore", kind: "ClusterSecretStore" }
            target: { name: "redis-secret", creationPolicy: "Owner" }
            data: [
                { secretKey: "redis-password", remoteRef: { key: "keycloak-internal", property: "redis-password" } }
            ]
        }
    }
}

# kustomization for the config/session-broker-keycloak/ directory.
def "broker-keycloak-config kustomization" [] {
    { resources: [
        "keycloak-hostnames-cm.yaml"
        "broker-hostnames-cm.yaml"
        "external-secret-keycloak-admin.yaml"
        "external-secret-keycloak-postgresql.yaml"
        "external-secret-keycloak-realm.yaml"
        "external-secret-session-broker.yaml"
        "external-secret-redis.yaml"
        "external-secret-redis-broker.yaml"
    ] }
}

# ---------------------------------------------------------------------------
# IO orchestrator — write the resolved host ConfigMaps into the private repo clone.
# ---------------------------------------------------------------------------

def "broker-keycloak-config render" [
    --private-path = "gitops-config"
    --domain:      string                                               # $env.domain_name
    --realm        = "enterpriseclaw"                                    # Keycloak realm name (broker constant)
    --auth-label   = "auth"                                             # MUST match broker-exposure (auth.<domain>)
    --broker-label = "broker"                                           # MUST match broker-exposure (broker.<domain>)
] {
    let auth_url     = $"https://($auth_label).($domain)"
    let broker_url   = $"https://($broker_label).($domain)"
    let issuer_url   = $"($auth_url)/realms/($realm)"
    let redirect_uri = $"($broker_url)/auth/callback"
    let dir = (abs-path --path=$"($private_path)/config/session-broker-keycloak" --replace-argument="")
    mkdir $dir

    (broker-keycloak-config keycloak-cm --auth-url=$auth_url --broker-url=$broker_url
    ) | to yaml | save $"($dir)/keycloak-hostnames-cm.yaml" --force

    (broker-keycloak-config broker-cm --issuer-url=$issuer_url --redirect-uri=$redirect_uri
    ) | to yaml | save $"($dir)/broker-hostnames-cm.yaml" --force

    # ExternalSecrets — wire the Keycloak/broker stack's secrets from AWS Secrets Manager
    # (these take no tenant args; the SM keys + namespaces are framework constants).
    (broker-keycloak-config es-keycloak-admin
    ) | to yaml | save $"($dir)/external-secret-keycloak-admin.yaml" --force

    (broker-keycloak-config es-keycloak-postgresql
    ) | to yaml | save $"($dir)/external-secret-keycloak-postgresql.yaml" --force

    (broker-keycloak-config es-keycloak-realm
    ) | to yaml | save $"($dir)/external-secret-keycloak-realm.yaml" --force

    (broker-keycloak-config es-session-broker
    ) | to yaml | save $"($dir)/external-secret-session-broker.yaml" --force

    (broker-keycloak-config es-redis
    ) | to yaml | save $"($dir)/external-secret-redis.yaml" --force

    # Same redis-password, second copy in ns session-broker for the Dapr Component.
    (broker-keycloak-config es-redis --namespace=session-broker
    ) | to yaml | save $"($dir)/external-secret-redis-broker.yaml" --force

    (broker-keycloak-config kustomization) | to yaml | save $"($dir)/kustomization.yaml" --force
}
