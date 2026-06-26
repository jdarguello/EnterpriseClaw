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

# kustomization for the config/session-broker-keycloak/ directory.
def "broker-keycloak-config kustomization" [] {
    { resources: [ "keycloak-hostnames-cm.yaml" "broker-hostnames-cm.yaml" ] }
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

    (broker-keycloak-config kustomization) | to yaml | save $"($dir)/kustomization.yaml" --force
}
