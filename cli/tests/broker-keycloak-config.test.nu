# broker-keycloak-config.test.nu — unit tests for the tenant Keycloak/broker hostname ConfigMaps.
#
# These are the EnterpriseClaw side of the cross-repo hostname contract: the CLI resolves the tenant
# host from $env.domain_name and writes `keycloak-hostnames` ConfigMaps the broker repo consumes via
# $(env:...) substitution. Tests assert the resolved values + the two target namespaces.
use std assert
source ../gitops/broker-keycloak-config.nu
source harness.nu

def "broker-keycloak-config-tests" [] {
    [
        # ---- pure generator: keycloak-namespace ConfigMap ----
        { name: "keycloak-cm carries the external issuer host + broker URL", run: {||
            let cm = (broker-keycloak-config keycloak-cm --auth-url="https://auth.example.io" --broker-url="https://broker.example.io")
            assert equal $cm.kind "ConfigMap"
            assert equal $cm.metadata.name "keycloak-hostnames"
            assert equal $cm.metadata.namespace "keycloak"
            assert equal ($cm.data.KC_HOSTNAME_URL) "https://auth.example.io"
            assert equal ($cm.data.KC_HOSTNAME_ADMIN_URL) "https://auth.example.io"
            # the realm's redirectUris/webOrigins substitute this in
            assert equal ($cm.data.BROKER_EXTERNAL_URL) "https://broker.example.io"
        }}

        # ---- pure generator: session-broker-namespace ConfigMap ----
        { name: "broker-cm carries the front-channel OAuth URLs", run: {||
            let cm = (broker-keycloak-config broker-cm --issuer-url="https://auth.example.io/realms/enterpriseclaw" --redirect-uri="https://broker.example.io/auth/callback")
            assert equal $cm.metadata.namespace "session-broker"
            assert equal ($cm.data.KEYCLOAK_ISSUER_URL) "https://auth.example.io/realms/enterpriseclaw"
            assert equal ($cm.data.KEYCLOAK_REDIRECT_URI) "https://broker.example.io/auth/callback"
        }}

        # ---- IO orchestrator: render resolves both CMs from the domain ----
        { name: "render writes both hostname ConfigMaps under config/session-broker-keycloak", run: {||
            let tmp = (make-tmpdir "kc-host")
            mkdir $"($tmp)/gitops-config"
            let cwd = (pwd)
            cd $tmp
            broker-keycloak-config render --private-path=gitops-config --domain="enterprise-claw.io"

            let dir = $"($tmp)/gitops-config/config/session-broker-keycloak"
            let kc = (open $"($dir)/keycloak-hostnames-cm.yaml")
            assert equal ($kc.metadata.namespace) "keycloak"
            assert equal ($kc.data.KC_HOSTNAME_URL) "https://auth.enterprise-claw.io"
            assert equal ($kc.data.BROKER_EXTERNAL_URL) "https://broker.enterprise-claw.io"

            let br = (open $"($dir)/broker-hostnames-cm.yaml")
            assert equal ($br.metadata.namespace) "session-broker"
            # issuer is auth-host + the realm; redirect is broker-host + the callback path
            assert equal ($br.data.KEYCLOAK_ISSUER_URL) "https://auth.enterprise-claw.io/realms/enterpriseclaw"
            assert equal ($br.data.KEYCLOAK_REDIRECT_URI) "https://broker.enterprise-claw.io/auth/callback"

            let k = (open $"($dir)/kustomization.yaml")
            assert equal $k.resources [ "keycloak-hostnames-cm.yaml" "broker-hostnames-cm.yaml" ]
            cd $cwd
            rm -rf $tmp
        }}

        # ---- realm + subdomain labels are configurable; issuer host tracks the auth label ----
        { name: "render honors a custom realm and subdomain labels", run: {||
            let tmp = (make-tmpdir "kc-host-custom")
            mkdir $"($tmp)/gitops-config"
            let cwd = (pwd)
            cd $tmp
            broker-keycloak-config render --private-path=gitops-config --domain="corp.net" --realm="acme" --auth-label="login" --broker-label="oauth"
            let br = (open $"($tmp)/gitops-config/config/session-broker-keycloak/broker-hostnames-cm.yaml")
            assert equal ($br.data.KEYCLOAK_ISSUER_URL) "https://login.corp.net/realms/acme"
            assert equal ($br.data.KEYCLOAK_REDIRECT_URI) "https://oauth.corp.net/auth/callback"
            cd $cwd
            rm -rf $tmp
        }}
    ]
}
