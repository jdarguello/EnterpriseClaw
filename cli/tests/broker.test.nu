# broker.test.nu — unit tests for the Session-Broker client's PURE reconcile-point mappers.
use std assert
source ../broker/main.nu
source harness.nu

def "broker-tests" [] {
    [
        # ---- parse-resolve: frozen contract {has_token, token} ----
        { name: "parse-resolve reads has_token+token (frozen contract)", run: {||
            let m = (broker parse-resolve { has_token: true, token: "jwt-abc" })
            assert equal $m.has_token true
            assert equal $m.token "jwt-abc"
        }}

        # ---- parse-resolve: no token → has_token false ----
        { name: "parse-resolve returns has_token:false when no token", run: {||
            let m = (broker parse-resolve { has_token: false })
            assert equal $m.has_token false
            assert equal $m.token ""
        }}

        # ---- parse-resolve: derive has_token from a present token when no bool ----
        { name: "parse-resolve derives has_token from token presence", run: {||
            let m = (broker parse-resolve { token: "jwt-xyz" })
            assert equal $m.has_token true
            assert equal $m.token "jwt-xyz"
        }}

        # ---- parse-resolve: defensive alt field names (reconcile point) ----
        { name: "parse-resolve accepts access_token/authenticated (defensive)", run: {||
            let m = (broker parse-resolve { authenticated: true, access_token: "jwt-alt" })
            assert equal $m.has_token true
            assert equal $m.token "jwt-alt"
        }}

        # ---- parse-resolve: missing / non-record ----
        { name: "parse-resolve handles missing fields / non-record", run: {||
            let m = (broker parse-resolve {})
            assert equal $m.has_token false
            assert equal $m.token ""
            let n = (broker parse-resolve "nope")
            assert equal $n.has_token false
        }}

        # ---- parse-login: frozen contract {login_url} ----
        { name: "parse-login reads login_url (frozen contract)", run: {||
            let m = (broker parse-login { login_url: "https://auth.example.com/realms/x/protocol/openid-connect/auth?..." })
            assert equal $m.ok true
            assert ($m.login_url | str starts-with "https://auth.example.com")
        }}

        # ---- parse-login: defensive alt field name ----
        { name: "parse-login accepts authorize_url (defensive)", run: {||
            let m = (broker parse-login { authorize_url: "https://auth/y" })
            assert equal $m.ok true
            assert equal $m.login_url "https://auth/y"
        }}

        # ---- parse-login: missing URL ----
        { name: "parse-login flags a missing URL", run: {||
            let m = (broker parse-login { something_else: true })
            assert equal $m.ok false
            let n = (broker parse-login "nope")
            assert equal $n.ok false
        }}
    ]
}
