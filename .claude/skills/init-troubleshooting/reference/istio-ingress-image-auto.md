# istio-ingress Degraded — gateway pod ImagePullBackOff on image `auto`

## Symptom

`istio-ingress` app Degraded; the gateway Deployment's pod is in `ImagePullBackOff`
trying to pull an image literally named **`auto`**.

## Root cause

The istio gateway Deployment intentionally ships `image: auto` — the
`istio-sidecar-injector` mutating webhook rewrites it to the real proxy image at
**pod admission**. On a fresh init, the gateway pod is admitted **before istiod has
registered/serves the injection webhook** (Argo marks `istio-system` Healthy before
istiod is actually serving; the sync-wave "Race B fix" in the helm-app does not
hold). The pod is created un-mutated, with the placeholder image, and stays broken —
admission only happens at pod creation, so it can never self-repair.

## Remediation

Delete the stuck pod. The replacement gets injected correctly — injection fires from
the pod's own `sidecar.istio.io/inject: "true"` label (no namespace label needed):

```sh
kubectl delete pod -n istio-ingress -l istio=ingressgateway   # or the stuck pod by name
kubectl get pods -n istio-ingress \
  -o jsonpath='{.items[*].spec.containers[*].image}'
# → registry.istio.io/release/proxyv2:<ver>-distroless  (NOT "auto")
```

## Durable fix (not yet done)

Real readiness gating of the gateway app behind istiod actually serving the
injection webhook (not just the Deployment reporting Available) — CLAUDE.md §6.