source ../../utils/generals.nu

#Install external-secrets operator (ESO) via Helm through GitOps!
def "external-secrets bootstrap" [] {
    #1. Install ESO
    external-secrets bootstrap gitops

    #2. Wait for ESO (webhook endpoints) to be ready instead of a blind sleep.
    #   The ClusterSecretStore validating webhook must have live endpoints before
    #   we apply the git-creds manifests, otherwise the apply fails with
    #   "no endpoints available for service external-secrets-webhook".
    external-secrets bootstrap wait

    #3. ESO Configuration
    external-secrets bootstrap config
}

#Gate on the External-Secrets Operator being ready before applying any ESO config.
#The ESO chart is synced by Argo CD, so the webhook Deployment / Service may not even
#exist for the first few seconds; the poll tolerates "not found" and keeps waiting.
def "external-secrets bootstrap wait" [
    --namespace =   "external-secrets"
    --timeout =     300        #Total seconds to wait before giving up.
    --interval =    5          #Seconds between polls.
] {
    let deadline = ((date now) + ($timeout * 1sec))

    #Hard requirement: the webhook Service must have at least one ready endpoint IP.
    mut webhook_ready = false
    while ((date now) < $deadline) {
        if (eso webhook-endpoints-ready --namespace=$namespace) {
            $webhook_ready = true
            break
        }
        sleep ($interval * 1sec)
    }

    if (not $webhook_ready) {
        error make { msg: $"external-secrets-webhook did not register ready endpoints in ($timeout)s; the ClusterSecretStore webhook would have no endpoints. Check the ESO Argo CD Application sync status in namespace '($namespace)'." }
    }

    #Cheap, best-effort gate on the controller + cert-controller being Available too
    #(not fatal if they lag — the webhook endpoints above are the hard requirement).
    for dep in ["external-secrets" "external-secrets-cert-controller"] {
        do {
            kubectl -n $namespace rollout status --watch --timeout=120s $"deployment/($dep)"
        } | complete | ignore
    }
}

#Returns true when the external-secrets-webhook Service has at least one ready endpoint IP.
#Tolerant of the Deployment/Service not existing yet (returns false on any kubectl failure).
def "eso webhook-endpoints-ready" [
    --namespace =   "external-secrets"
] {
    let res = (do {
        kubectl -n $namespace get endpoints external-secrets-webhook -o jsonpath='{.subsets[*].addresses[*].ip}'
    } | complete)

    if ($res.exit_code != 0) {
        return false
    }
    return (eso endpoints-string-ready --ips=$res.stdout)
}

#Pure predicate: given the jsonpath output of endpoint address IPs, is at least one present?
#Extracted so it can be unit-tested without a cluster.
def "eso endpoints-string-ready" [
    --ips:  string      #Raw stdout from the endpoints jsonpath query.
] {
    return (($ips | str trim) != "")
}

#Configures External-Secrets Operator (ESO) with user's
def "external-secrets bootstrap config" [
    --private-path="gitops-config/helm/kube-essentials/external-secrets/git-creds/"    #Private config from user's private repository.
] {
    #1. Get private config
    let manifest_files = list-files --path=$private_path --except-filenames="kustomization.yaml"

    #2. Create k8s objects (retry a couple of times to absorb transient
    #   ClusterSecretStore -> ExternalSecret ordering flakes).
    for $file in $manifest_files {
        eso apply-with-retry --file=$file
    }
}

#Apply a single manifest, retrying a couple of times on failure. The readiness gate
#above should make failures rare, but ordering (ClusterSecretStore before ExternalSecret)
#can still flake, so a short retry loop keeps the bootstrap resilient.
def "eso apply-with-retry" [
    --file:     string
    --attempts =    3       #Total attempts before giving up.
    --interval =    5       #Seconds between attempts.
] {
    mut attempt = 1
    mut applied = false
    while ($attempt <= $attempts) {
        let res = (do { kubectl apply -f $file } | complete)
        if ($res.exit_code == 0) {
            $applied = true
            break
        }
        print $"(ansi yellow)kubectl apply -f ($file) failed (attempt ($attempt)/($attempts)): ($res.stderr | str trim)(ansi reset)"
        $attempt = $attempt + 1
        if ($attempt <= $attempts) {
            sleep ($interval * 1sec)
        }
    }

    if (not $applied) {
        error make { msg: $"kubectl apply -f ($file) failed after ($attempts) attempts." }
    }
}

def "external-secrets bootstrap gitops" [] {
    #1. Get Helm-ESO path from GitOps directory
    let eso_path = abs-path --path="gitops/helm-eso.yaml" --replace-argument="/cli"

    #2. Install it via kubectl (server-side apply: idempotent so a re-run of a
    #   failed init updates the ESO ApplicationSet instead of failing on "already exists").
    kubectl apply --server-side -f $eso_path
}