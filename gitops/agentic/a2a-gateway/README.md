# A2A ingress gateway — the front door for platform-agent

This directory is the **A2A ingress enforcement plane**: the agentgateway L7 waypoint that
validates the Keycloak user JWT before any A2A message/send reaches `platform-agent`. It is
distinct from [../mcp-gateway/](../mcp-gateway/) (which gates MCP tool calls) and covers the one
demo hop that remains unproven after the dry-run: **JWT validation at the A2A ingress** (the
`Workflow → agentgateway → platform-agent` path vs the already-proven `agent → agentgateway → MCP`
path).

## Role in the demo spine

```
Workflow CLI A2A client
  └─ POST http://agentic-a2a-gw.kagent:8080/platform-agent
       │  Authorization: Bearer <Keycloak user JWT>
       │
       ▼
  agentgateway (agentic-a2a-gw proxy)          ← THIS WAYPOINT
       │  validates JWT (Strict, JWKS from Keycloak)
       │  admits: has(jwt.sub) + valid aud `enterpriseclaw-agents`
       │  forwards bearer (passthrough=ON) → platform-agent receives it
       │  strips /platform-agent prefix → forwards to agent root /
       │
       ▼
  platform-agent (A2A JSON-RPC server :8080)
       │  receives bearer via A2A request headers
       │  calls tools via allowedHeaders: ["Authorization"]
       │
       ▼
  mcp-gateway (agentic-mcp-gw proxy)           ← ALREADY PROVEN (dry-run iter2 stage B)
       │  validates same JWT per-route
       │  /issues  → requires issue:create    (alice ✅  juan ✅)
       │  /provisioning → requires db:provision:dev (alice ❌ 403, juan ✅)
```

## The two-identity rails at this hop

| Rail | Identity | Enforced by | Action at this hop |
|---|---|---|---|
| User | Keycloak JWT (sub, realm roles, resource_access) | agentgateway `traffic.jwtAuthentication` + `traffic.authorization` | Strict validation; 401 tokenless/forged; 403 no-sub |
| Workload | ambient-mesh SPIFFE/mTLS principal | ztunnel (L4) beneath the waypoint | mTLS to the proxy; SPIFFE principal visible for future CEL gating |

The user JWT rail is the focus here. The workload rail (ztunnel) is automatic — every pod-to-pod
hop in the ambient mesh is mTLS-authenticated; no additional `PeerAuthentication` or `AuthorizationPolicy`
is authored here (a future hardening pass can add `source.principal` CEL to the authorization
expression to lock down which workloads may even reach this gateway).

## Why `backend.auth.passthrough` is ON here (critical difference from mcp-gateway)

`mcp-gateway/policies.yaml` leaves passthrough OFF. In that case the user JWT **stops** at the MCP
waypoint — the downstream GitHub MCP authenticates to GitHub with its own `github-creds` bot token,
not the user's JWT. Two separate rails by design.

**At the A2A ingress the logic is different:** platform-agent MUST receive the user bearer to
propagate it onward to the MCP-gateway hop. Without the bearer, `allowedHeaders: ["Authorization"]`
on the agent's tool refs has nothing to forward — and without it on the wire at the MCP-gateway,
the claim-gating in `mcp-gateway/policies.yaml` has nothing to validate.

Per `crds.md` gotcha #6 / `jwt-propagation.md`: "under active `jwtAuthentication` the validated
bearer is CONSUMED at the gateway ... `backend.auth.passthrough` is the documented lever to
re-forward it." `passthrough: {}` is set on `spec.policies.auth` of the `AgentgatewayBackend`
(`backend.yaml`), which re-attaches the validated bearer to the upstream request before forwarding.

Flow with passthrough ON:
```
Workflow → agentgateway (validates JWT) → passthrough → platform-agent (receives JWT)
platform-agent → allowedHeaders:["Authorization"] → mcp-gateway (validates JWT again per-route)
```

## The reachable A2A URL for the Workflow (Task C hand-off)

```
A2A_GW_URL = http://agentic-a2a-gw.kagent:8080/platform-agent
```

The HTTPRoute matches `PathPrefix /platform-agent` and rewrites it to `/` before forwarding to the
agent's A2A root. The CLI A2A client should POST `message/send` to this URL with
`Authorization: Bearer <user JWT>` and the standard A2A JSON-RPC body (see crds.md).

## Status checks (after Argo syncs agentic-a2a-gateway)

```bash
kubectl get gateway -n kagent agentic-a2a-gw        # Programmed=True
kubectl get httproute -n kagent platform-agent-route # ResolvedRefs=True
kubectl get agentgatewaybackend -n kagent platform-agent-a2a-backend  # Accepted=True
kubectl get agentgatewaybackend -n kagent platform-agent-a2a-backend -o yaml | grep -A5 status
kubectl get agentgatewaypolicy -n kagent platform-agent-jwt           # Accepted=True, Attached=True
```

## A2A backend CRD shape uncertainty

`AgentgatewayBackend.spec.a2a` is the one field not empirically proven on 1.3.1 (the `mcp` and
`ai` sub-resources are proven; `a2a` is by analogy). After the agentgateway-crds Application syncs:

```bash
kubectl explain agentgatewaybackend.spec.a2a
kubectl explain agentgatewaybackend.spec.a2a.targets
kubectl explain agentgatewaybackend.spec.a2a.targets.static
```

If `spec.a2a.targets` does not exist: try `spec.a2a.backendRef.{name,port}` (Option B) or
`spec.a2a.host` (Option C mirroring the standalone config). The `AgentgatewayBackend` will be
`Accepted=False` if the shape is wrong — that is the signal. See `backend.yaml` for the three
candidate shapes.

## Spike test plan (the unproven hop — run during the live join)

### Prerequisites

- Argo application `agentic-a2a-gateway` synced and all resources Accepted/Programmed.
- The backend CRD shape confirmed and corrected if needed (run `kubectl explain` above first).
- Keycloak `enterpriseclaw` realm running (Session-Broker stack healthy).
- `platform-agent` pod Running and `a2aConfig` instantiated (Service `platform-agent.kagent:8080`
  reachable).

### Step 1 — Confirm the proxy is running

```bash
# The Gateway provisions a Deployment + Service named after the Gateway object:
kubectl get svc -n kagent agentic-a2a-gw
kubectl get deploy -n kagent agentic-a2a-gw
```

### Step 2 — Mint tokens (mirror the dry-run stage-B approach)

```bash
KEYCLOAK_URL="http://keycloak.keycloak.svc.cluster.local"  # or port-forward to localhost
REALM="enterpriseclaw"
CLIENT_ID="dryrun-cli"            # or the session-broker's Keycloak client
CLIENT_SECRET="<from SM keycloak-internal / realm-secrets>"

# Alice token (has agent-user role, audience enterpriseclaw-agents):
ALICE_TOKEN=$(curl -s -X POST "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}" \
  -d "username=alice&password=<alice-pw-from-SM-keycloak-internal>" \
  | jq -r .access_token)

# Verify the audience and sub are present:
echo $ALICE_TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | jq '{sub,aud,realm_access}'
```

To run the probe from inside the cluster (avoids port-forwarding):

```bash
kubectl run -it --rm probe --image=curlimages/curl --restart=Never -n kagent -- sh
```

### Step 3 — Drive the A2A endpoint with alice's token (expect 200)

```bash
A2A_GW_URL="http://agentic-a2a-gw.kagent:8080/platform-agent"

# A2A JSON-RPC message/send (A2A 0.3 spec — note `kind`, not `type`, on parts):
curl -v -X POST "${A2A_GW_URL}" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ALICE_TOKEN}" \
  -d '{
    "jsonrpc": "2.0",
    "id": "test-1",
    "method": "message/send",
    "params": {
      "message": {
        "role": "user",
        "kind": "message",
        "parts": [{ "kind": "text", "text": "List open GitHub issues in the entepriseclaw repo." }],
        "messageId": "probe-001"
      }
    }
  }'
# Expected: HTTP 200, body = A2A Task with result.history[] including the model's response
# and a tool call to github-issues (issue_read / list_issues).
```

### Step 4 — No token (expect 401)

```bash
curl -v -X POST "${A2A_GW_URL}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"2","method":"message/send","params":{"message":{"role":"user","kind":"message","parts":[{"kind":"text","text":"hi"}],"messageId":"probe-002"}}}'
# Expected: HTTP 401 (agentgateway Strict mode rejects tokenless)
```

### Step 5 — Forged token (expect 401)

```bash
# A syntactically valid JWT with a bad signature (HS256 signed with wrong key):
FORGED="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJoYWNrZXIiLCJhdWQiOiJlbnRlcnByaXNlY2xhdy1hZ2VudHMiLCJpc3MiOiJodHRwOi8va2V5Y2xvYWsua2V5Y2xvYWsuc3ZjL3JlYWxtcy9lbnRlcnByaXNlY2xhdyIsImV4cCI6OTk5OTk5OTk5OX0.bad_signature"
curl -v -X POST "${A2A_GW_URL}" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${FORGED}" \
  -d '{"jsonrpc":"2.0","id":"3","method":"message/send","params":{"message":{"role":"user","kind":"message","parts":[{"kind":"text","text":"hi"}],"messageId":"probe-003"}}}'
# Expected: HTTP 401 InvalidSignature
```

### Step 6 — Wrong audience token (expect 401)

```bash
# Mint a token for the `issue-tracker` audience (a per-MCP audience, NOT the broad agent audience):
WRONG_AUD_TOKEN=$(curl -s -X POST "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=issue-tracker&client_secret=<issue-tracker-secret>" \
  -d "username=alice&password=<alice-pw>" \
  | jq -r .access_token)
curl -v -X POST "${A2A_GW_URL}" \
  -H "Authorization: Bearer ${WRONG_AUD_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"4","method":"message/send","params":{"message":{"role":"user","kind":"message","parts":[{"kind":"text","text":"hi"}],"messageId":"probe-004"}}}'
# Expected: HTTP 401 (audience mismatch — token has aud=issue-tracker, policy requires
# enterpriseclaw-agents)
```

### Step 7 — Confirm the bearer transits the waypoint and reaches platform-agent

Two signals:

1. **agentgateway access log** — the proxy pod logs each request; look for the A2A protocol line:
   ```bash
   kubectl logs -n kagent deploy/agentic-a2a-gw -f \
     | grep -E 'protocol=a2a|a2a.method|platform-agent'
   # (A2A access log line format may differ from the MCP `protocol=mcp mcp.method.name=...` form;
   # grep for `platform-agent` or `message/send` as a fallback until the exact format is known.)
   ```

2. **End-to-end tool call success** — if alice's Step 3 probe returns a Task with a tool call
   `function_call` to `list_issues` (or any github-issues tool) that succeeded, the bearer survived
   `Workflow→a2a-gateway→platform-agent→mcp-gateway` intact. A successful tool call is the
   definitive proof: the mcp-gateway would have 401d it if the bearer was absent or consumed.
   ```bash
   # In the Step 3 response body, look for:
   # result.history[].parts[].functionCall.name  = "list_issues" (or issue_read, etc.)
   # result.history[].parts[].functionResponse.response  = <list of issues> (not an error)
   ```

### Step 8 — Alice vs Juan claim-gate (demonstrates the mesh decides, not the model)

```bash
# Juan token (senior-engineer role, holds db:provision:dev):
JUAN_TOKEN=$(curl -s ... username=juandavidarguello@gmail.com ...)

# Both alice and juan should reach platform-agent (both have agent-user + sub):
curl -H "Authorization: Bearer ${ALICE_TOKEN}" ... # Step 3 body → 200
curl -H "Authorization: Bearer ${JUAN_TOKEN}"  ... # same → 200

# But when platform-agent calls infra-provisioning, alice gets 403 from mcp-gateway:
# Prompt that would trigger the infra tool: "provision a dev database named test-db"
# alice→tool call→mcp-gateway /provisioning→403 (alice lacks db:provision:dev)
# juan →tool call→mcp-gateway /provisioning→200 (juan has db:provision:dev)
# The 403 appears in platform-agent's response as the clean systemMessage-guided text.
```

## Prereqs

- Argo Application `agentic-a2a-gateway` (auto-onboarded by the `agentic` ApplicationSet, no
  private-repo change needed).
- kagent-trio controllers healthy (agentgateway, kagent, kmcp — installed from `gitops/helm/agents/`).
- Session-Broker stack healthy (Keycloak `enterpriseclaw` realm running) so the JWKS backendRef
  resolves. The AgentgatewayPolicy will report `Attached=False` if JWKS is unreachable at xDS time.
- `platform-agent` pod Running with `a2aConfig` populated (Service `platform-agent.kagent:8080`
  reachable from the proxy).
