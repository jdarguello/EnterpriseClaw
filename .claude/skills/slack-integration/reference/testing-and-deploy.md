# Testing + deploy procedure

## Synthetic signed-event replay (test without a human in Slack)

The single most useful technique here. POST a properly-signed synthetic `event_callback` to `/slack`. The EventSource validates the signature + verification token, then re-marshals through slack-go and dispatches **exactly** like a real Slack delivery — so the dispatched schema is production-identical and the whole path (EventSource → Sensor → Workflow → reply) runs. Reads secrets internally; never prints them.

```python
import json, subprocess, hmac, hashlib, time, urllib.request
d = json.loads(subprocess.check_output(["aws","secretsmanager","get-secret-value",
      "--secret-id","slack-creds","--query","SecretString","--output","text"]).decode())
token, signing = d["verification_token"], d["signing_secret"].encode()
body = json.dumps({"token": token, "team_id":"T0DEMO","api_app_id":"A0DEMO",
  "event": {"type":"app_mention","user":"U_ALICE","text":"<@U0BOTID> deploy a payments service",
            "ts":"1719777600.000100","thread_ts":"","channel":"C_DEMO","event_ts":"1719777600.000100"},
  "type":"event_callback","event_id":"Ev_SYNTH","event_time":1719777600})
ts = str(int(time.time()))
sig = "v0=" + hmac.new(signing, f"v0:{ts}:{body}".encode(), hashlib.sha256).hexdigest()
req = urllib.request.Request("https://events.enterprise-claw.io/slack", data=body.encode(),
  headers={"Content-Type":"application/json","X-Slack-Request-Timestamp":ts,"X-Slack-Signature":sig}, method="POST")
with urllib.request.urlopen(req, timeout=15) as r:
    print(r.status, r.read().decode())   # -> 200 'success'
```

- **What a fake `channel` proves:** the Workflow runs end-to-end; the reply step returns `ok=False error=channel_not_found`. That's the **plumbing-OK signal** — token valid (else `not_authed`/`invalid_auth`), egress works, secret mounts, image pulls. Only a *real* channel the bot is in returns `ok=True` and actually posts (synthetic can't).
- **For url_verification only** (Request-URL registration): set the body `type` to `url_verification` with a `challenge`, same signing — assert HTTP 200 + the challenge is echoed (response is `<challenge>success`).

## Schema-discovery trick — the temporary `log` trigger

To dump the **raw** dispatched payload to the sensor pod logs (ground truth for field names), add a second trigger to the Sensor:

```yaml
  triggers:
    - template:
        name: slack-log
        log:
          intervalSeconds: 1
```

Then `kubectl logs -n argo-events -l sensor-name=slack-mention | grep log/log.go` shows the exact JSON (this is how the capital-D `Data` schema was confirmed). Remove it once the schema is known.

## Deploy procedure (Argo CD owns these — direct apply is reverted)

The Sensor + ExternalSecrets are owned by Argo CD apps `config-argo-events` and `config-argo-workflows`, which **self-heal** — a `kubectl apply` of an edit is reverted in seconds. To deploy a change:

1. **Push to the PUBLIC repo `main`** (the auto-sync hook's push is broken — use the valid `GH_TOKEN` from `cli/.env`: `git push "https://x-access-token:${GH_TOKEN}@github.com/jdarguello/EnterpriseClaw.git" HEAD:main`). The config apps remote-reference public `?ref=main`.
2. **Hard-refresh** the owning app: `kubectl annotate application config-argo-events -n argocd argocd.argoproj.io/refresh=hard --overwrite` (and/or `config-argo-workflows`). Argo re-pulls `main` and applies the new manifest.
3. **For a changed secret/ExternalSecret only:** force ESO re-sync `kubectl annotate es <name> -n <ns> force-sync="$(date +%s)" --overwrite` (ESO refreshInterval is 1h) **AND restart the consumer pod** — the eventsource pod loads `slack-secret` at startup: `kubectl delete pod -n argo-events -l eventsource-name=slack`.

## Useful inspection commands

```bash
# eventsource received + dispatched?  (look for "Succeeded to publish an event")
kubectl logs -n argo-events -l eventsource-name=slack --tail=30
# sensor trigger result / errors
kubectl logs -n argo-events -l sensor-name=slack-mention --tail=30
# latest workflow + its params + node phases
kubectl get wf -n argo --sort-by=.metadata.creationTimestamp | tail
kubectl get wf -n argo <wf> -o jsonpath='{range .spec.arguments.parameters[*]}{.name}={.value}{"\n"}{end}'
# reply step output (the chat.postMessage response)
kubectl logs -n argo <wf>-slack-reply-<id> -c main
```

## Non-obvious environment notes

- Non-interactive Devbox: `cd cli && eval "$(devbox shellenv 2>/dev/null)"` to get `kubectl`/`aws`/`nu` on PATH (the bare `devbox -C cli shellenv` form did not export them reliably).
- CLI unit tests: from `cli/`, `nu tests/run.nu` (cluster-free; runs the pure generators incl. the slack payload builder).
