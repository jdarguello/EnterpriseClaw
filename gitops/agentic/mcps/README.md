# Agentic MCP servers

Tool servers the agents call, fronted by agentgateway's MCP federation (user-JWT validation +
claim-gated tool authz, per CLAUDE.md §2.2).

Empty for now — the first real agent, [general-classifier](../agents/general-classifier/), is the
JWT-less triage door and has **no tools by design**. The first MCP to land here is the
kmcp-managed **GitHub `MCPServer`** that opens PRs (the demo's change-delivery path).

To add one: drop its manifest here, list it in [kustomization.yaml](./kustomization.yaml), and the
`agentic` ApplicationSet onboards it on the next sync.
