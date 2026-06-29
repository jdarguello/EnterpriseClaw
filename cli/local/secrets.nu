# Local-testing secrets — the substitute for ESO + IRSA pulling from AWS Secrets Manager.
#
# In the cloud flow, the External-Secrets Operator (running with an IRSA role) syncs values from AWS
# Secrets Manager into k8s Secrets. The local VM has no IRSA, so instead we reuse the STATIC AWS creds
# already in .env (loaded by Devbox) to read the very same SM secrets and create the k8s Secrets
# directly. Secret VALUES are never printed.
#
# IRSA debt (tracked): this only covers the SM-backed secrets. Other IRSA-based access paths still need
# a local story — Bedrock `InvokeModel` on the agentgateway SA, S3 pipe-storage on the Argo SAs, etc.
# See `main local secrets bedrock` (placeholder) and the local-testing-cli-path memory.
source ../utils/generals.nu

# Lenient JSON → k8s Secret builder. The GitHub App PEM in `github-creds` holds raw newlines, which is
# not strict JSON, so we parse with Python's strict=False and emit a Secret manifest (every SM key
# becomes a stringData entry). Kept as a module-level constant so each caller reuses the same shim.
const PY_BUILD_SECRET = 'import sys, json, os
d = json.loads(sys.stdin.read(), strict=False)
d.update(json.loads(os.environ.get("EC_EXTRA", "{}")))
meta = {"name": os.environ["EC_NAME"], "namespace": os.environ["EC_NS"]}
lab = os.environ.get("EC_LABEL", "")
if lab:
    k, v = lab.split("=", 1)
    meta["labels"] = {k: v}
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "metadata": meta, "type": "Opaque", "stringData": d}))'

# Fetch an AWS Secrets Manager secret and create/replace it as a k8s Secret, mapping every SM key into
# stringData. `--extra` injects additional stringData keys (e.g. Argo CD's required `type: git`).
def "local secret from-sm" [
    --secret-id:  string                 # AWS SM secret name
    --name:       string                 # k8s Secret name
    --namespace:  string                 # k8s namespace
    --label       = ""                   # optional "key=value" label (e.g. argocd repo-creds)
    --extra:      record = {}            # extra stringData keys to merge in
] {
    let region = ($env.region | str trim -c '"')
    let raw = (^aws secretsmanager get-secret-value --secret-id $secret_id --region $region --query SecretString --output text)
    let manifest = (
        with-env {EC_NAME: $name, EC_NS: $namespace, EC_LABEL: $label, EC_EXTRA: ($extra | to json)} {
            $raw | ^python3 -c $PY_BUILD_SECRET
        }
    )
    $manifest | ^kubectl apply -f -
}

# THE private-repo unblocker: an Argo CD GitHub-App repo-creds Secret so Argo can clone the PRIVATE
# sandbox repo. Mirrors what ESO would create from `github-creds` (helm/.../git-creds/3.external-secret),
# adding the `type: git` data key Argo requires. Matches repos by the `url` prefix in github-creds.
def "local secret argocd-repo" [] {
    local secret from-sm --secret-id="github-creds" --name="git-creds" --namespace="argocd" --label="argocd.argoproj.io/secret-type=repo-creds" --extra={type: "git"}
}

# Create the SM-backed secrets the local cluster needs. For now just the argocd repo-creds (required
# BEFORE the app-of-apps root syncs, so Argo can read the private repo). Runtime secrets for
# argo / argo-events / kagent are layered in once their namespaces exist (next iteration).
def "main local secrets" [] {
    local secret argocd-repo
}
