---
mode: agent
description: Load the authoritative kagent-trio reference (kagent + kmcp + agentgateway) before working on it.
---

# kagent trio reference

Use this before installing, pinning, configuring, or debugging the **kagent trio** on
Kubernetes/Argo CD, or when working on **JWT / two-identity propagation** (user JWT +
workload SPIFFE) through it.

- **kagent** — the agent runtime (Agent + ModelConfig CRDs, A2A server).
- **kmcp** — controller + `MCPServer` CRD that *runs* MCP servers on-cluster.
- **agentgateway** — the L7 data plane (A2A routing, MCP federation, JWT/auth), deployed as
  the Istio ambient L7 waypoint; also the LLM gateway to Bedrock.

**Read these repo files before answering or editing** (they are the authoritative,
version-pinned source — versions are pinned as one compatible *set*, pre-1.0):
- `.claude/skills/kagent-trio/SKILL.md` (overview + entry points)
- `.claude/skills/kagent-trio/reference/install.md` (Helm install, version pins, namespaces)
- `.claude/skills/kagent-trio/reference/crds.md` (Agent / ModelConfig / MCPServer / gateway CRDs)
- `.claude/skills/kagent-trio/reference/agentgateway.md` (waypoint, routes, policies, LLM gateway)
- `.claude/skills/kagent-trio/reference/jwt-propagation.md` (the `kagent → agentgateway → MCP`
  propagation + claim-gating — the riskiest unknown; dry-run findings)

Remember: **the mesh is the security boundary, not the model.** JWT propagation is a hard
requirement and is *upstream* of enforcement — a tokenless privileged tool call must be
rejected. Never invent CRD fields or Helm values — verify against these docs and the pinned
chart versions. Cross-reference `/session-broker` for the identity side.
