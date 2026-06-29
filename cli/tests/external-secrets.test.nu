# external-secrets.test.nu — unit tests for the ESO readiness gate.
#
# Focus: the pure predicate that decides whether the external-secrets-webhook Service has
# live endpoints (the hard requirement before applying the ClusterSecretStore manifests).
# Cluster-free: only the pure string-check is exercised, mirroring the rest of the suite.
use std assert
source ../gitops/external-secrets/bootstrap.nu

def "external-secrets-tests" [] {
    [
        { name: "a single endpoint IP counts as ready", run: {||
            assert equal (eso endpoints-string-ready --ips="10.0.1.5") true
        }}

        { name: "multiple space-separated IPs count as ready", run: {||
            assert equal (eso endpoints-string-ready --ips="10.0.1.5 10.0.2.7") true
        }}

        { name: "empty string is not ready (no endpoints yet)", run: {||
            assert equal (eso endpoints-string-ready --ips="") false
        }}

        { name: "whitespace-only string is not ready", run: {||
            assert equal (eso endpoints-string-ready --ips="   ") false
        }}

        { name: "trailing newline does not falsely count as ready", run: {||
            assert equal (eso endpoints-string-ready --ips="\n") false
        }}
    ]
}
