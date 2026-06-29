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
            # the overlay now spans the two hostname CMs PLUS the five ExternalSecrets
            assert equal $k.resources [
                "keycloak-hostnames-cm.yaml"
                "broker-hostnames-cm.yaml"
                "external-secret-keycloak-admin.yaml"
                "external-secret-keycloak-postgresql.yaml"
                "external-secret-keycloak-realm.yaml"
                "external-secret-session-broker.yaml"
                "external-secret-redis.yaml"
            ]
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

        # ---- ExternalSecret generators: shared shape (store/refresh/target policy) ----
        { name: "all four ExternalSecrets share store, refresh interval, and creationPolicy", run: {||
            let all = [
                (broker-keycloak-config es-keycloak-admin)
                (broker-keycloak-config es-keycloak-postgresql)
                (broker-keycloak-config es-keycloak-realm)
                (broker-keycloak-config es-session-broker)
            ]
            for es in $all {
                assert equal $es.apiVersion "external-secrets.io/v1beta1"
                assert equal $es.kind "ExternalSecret"
                assert equal $es.spec.refreshInterval "1h"
                assert equal $es.spec.secretStoreRef.name "git-creds-secretstore"
                assert equal $es.spec.secretStoreRef.kind "ClusterSecretStore"
                assert equal $es.spec.target.creationPolicy "Owner"
                # target.name mirrors the ExternalSecret name (it owns the synced Secret)
                assert equal $es.spec.target.name $es.metadata.name
            }
        }}

        # ---- ExternalSecret: keycloak-admin ----
        { name: "es-keycloak-admin pulls admin-password from keycloak-internal into ns keycloak", run: {||
            let es = (broker-keycloak-config es-keycloak-admin)
            assert equal $es.metadata.name "keycloak-admin-secret"
            assert equal $es.metadata.namespace "keycloak"
            assert equal ($es.spec.data | length) 1
            let d = ($es.spec.data | get 0)
            assert equal $d.secretKey "admin-password"
            assert equal $d.remoteRef.key "keycloak-internal"
            assert equal $d.remoteRef.property "admin-password"
        }}

        # ---- ExternalSecret: keycloak-postgresql ----
        { name: "es-keycloak-postgresql pulls both db passwords from keycloak-internal into ns keycloak", run: {||
            let es = (broker-keycloak-config es-keycloak-postgresql)
            assert equal $es.metadata.name "keycloak-postgresql-secret"
            assert equal $es.metadata.namespace "keycloak"
            # map secretKey -> {key, property} for order-independent assertions
            let m = ($es.spec.data | reduce --fold {} {|it, acc| $acc | insert $it.secretKey { key: $it.remoteRef.key, property: $it.remoteRef.property } })
            assert equal ($m | columns | length) 2
            assert equal ($m.password.key) "keycloak-internal"
            assert equal ($m.password.property) "password"
            assert equal ($m."postgres-password".key) "keycloak-internal"
            assert equal ($m."postgres-password".property) "postgres-password"
        }}

        # ---- ExternalSecret: keycloak-realm ----
        { name: "es-keycloak-realm maps the four realm-import secrets (incl. google-idp) into ns keycloak", run: {||
            let es = (broker-keycloak-config es-keycloak-realm)
            assert equal $es.metadata.name "keycloak-realm-secrets"
            assert equal $es.metadata.namespace "keycloak"
            let m = ($es.spec.data | reduce --fold {} {|it, acc| $acc | insert $it.secretKey { key: $it.remoteRef.key, property: $it.remoteRef.property } })
            assert equal ($m | columns | length) 4
            assert equal ($m.SESSION_BROKER_CLIENT_SECRET.key) "keycloak-internal"
            assert equal ($m.SESSION_BROKER_CLIENT_SECRET.property) "session-broker-client-secret"
            assert equal ($m.KAGENT_CONTROLLER_CLIENT_SECRET.key) "keycloak-internal"
            assert equal ($m.KAGENT_CONTROLLER_CLIENT_SECRET.property) "kagent-controller-client-secret"
            assert equal ($m.ALICE_PASSWORD.key) "keycloak-internal"
            assert equal ($m.ALICE_PASSWORD.property) "alice-password"
            # Google IdP secret comes from a DIFFERENT SM entry
            assert equal ($m.GOOGLE_CLIENT_SECRET.key) "google-idp"
            assert equal ($m.GOOGLE_CLIENT_SECRET.property) "CLIENT_SECRET"
        }}

        # ---- ExternalSecret: session-broker ----
        { name: "es-session-broker pulls the shared client secret into ns session-broker", run: {||
            let es = (broker-keycloak-config es-session-broker)
            assert equal $es.metadata.name "session-broker-secret"
            assert equal $es.metadata.namespace "session-broker"
            assert equal ($es.spec.data | length) 1
            let d = ($es.spec.data | get 0)
            assert equal $d.secretKey "keycloak-client-secret"
            assert equal $d.remoteRef.key "keycloak-internal"
            assert equal $d.remoteRef.property "session-broker-client-secret"
        }}

        # ---- CRITICAL: broker + keycloak-realm MUST share the same SM source for the client secret ----
        { name: "session-broker-secret and keycloak-realm-secrets source the SAME SM property for the client secret", run: {||
            let realm = (broker-keycloak-config es-keycloak-realm)
            let broker = (broker-keycloak-config es-session-broker)
            let realm_client = ($realm.spec.data | where secretKey == "SESSION_BROKER_CLIENT_SECRET" | get 0)
            let broker_client = ($broker.spec.data | where secretKey == "keycloak-client-secret" | get 0)
            assert equal $realm_client.remoteRef.key $broker_client.remoteRef.key
            assert equal $realm_client.remoteRef.property $broker_client.remoteRef.property
            assert equal $broker_client.remoteRef.key "keycloak-internal"
            assert equal $broker_client.remoteRef.property "session-broker-client-secret"
        }}

        # ---- ExternalSecret: redis ----
        { name: "es-redis pulls redis-password into ns redis", run: {||
            let es = (broker-keycloak-config es-redis)
            assert equal $es.metadata.name "redis-secret"
            assert equal $es.metadata.namespace "redis"
            assert equal ($es.spec.data | length) 1
            let d = ($es.spec.data | get 0)
            assert equal $d.secretKey "redis-password"
            assert equal $d.remoteRef.key "keycloak-internal"
            assert equal $d.remoteRef.property "redis-password"
        }}

        # ---- kustomization now lists all seven resources (2 CMs + 5 ExternalSecrets) ----
        { name: "kustomization lists both ConfigMaps and all five ExternalSecrets", run: {||
            let k = (broker-keycloak-config kustomization)
            assert equal $k.resources [
                "keycloak-hostnames-cm.yaml"
                "broker-hostnames-cm.yaml"
                "external-secret-keycloak-admin.yaml"
                "external-secret-keycloak-postgresql.yaml"
                "external-secret-keycloak-realm.yaml"
                "external-secret-session-broker.yaml"
                "external-secret-redis.yaml"
            ]
        }}

        # ---- render writes the four ExternalSecret files alongside the CMs ----
        { name: "render writes all four ExternalSecret YAMLs into the overlay dir", run: {||
            let tmp = (make-tmpdir "kc-es")
            mkdir $"($tmp)/gitops-config"
            let cwd = (pwd)
            cd $tmp
            broker-keycloak-config render --private-path=gitops-config --domain="enterprise-claw.io"
            let dir = $"($tmp)/gitops-config/config/session-broker-keycloak"

            let admin = (open $"($dir)/external-secret-keycloak-admin.yaml")
            assert equal $admin.kind "ExternalSecret"
            assert equal $admin.metadata.namespace "keycloak"

            let broker = (open $"($dir)/external-secret-session-broker.yaml")
            assert equal $broker.metadata.namespace "session-broker"
            let bd = ($broker.spec.data | get 0)
            assert equal $bd.remoteRef.property "session-broker-client-secret"

            # kustomization on disk matches the generator
            let k = (open $"($dir)/kustomization.yaml")
            assert equal ($k.resources | length) 7
            cd $cwd
            rm -rf $tmp
        }}
    ]
}
