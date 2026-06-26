# CLI unit tests

Cluster-free unit tests for the `enterpriseclaw` Nushell CLI. They exercise the **pure
manifest generators** and **file-generation logic** that `enterpriseclaw init` uses to wire the
agentic platform (kagent trio + agentic CRs) and the Session-Broker into the tenant app-of-apps —
without provisioning or contacting any cluster.

## Run

From `cli/`, inside Devbox:

```nu
nu tests/run.nu
```

Exits non-zero if any test fails.

## Layout

- `run.nu` — dependency-free runner. Sources each suite, runs every test closure under
  `try/catch`, prints pass/fail, exits non-zero on failure.
- `harness.nu` — shared helpers (`make-tmpdir`, `seed-private-repo`).
- `*.test.nu` — one suite per area. A suite is a command returning a list of
  `{ name: string, run: closure }`; each closure asserts via `std assert` and throws on failure.

## Coverage

- `app-of-apps.test.nu` — the `agents` / `agentic` ApplicationSets and `session-broker`
  Application generators, the idempotent kustomization merge, and the `register-*` IO orchestrators
  (write the definitions into a seeded private-repo clone, register them, stay idempotent on re-run).
- `broker-exposure.test.nu` — the Istio `Gateway` / `VirtualService` generators for the
  `auth.<domain>` (Keycloak) and `broker.<domain>` (callback) host-routes, and the `render` IO that
  resolves them from `$env.domain_name`.

## Adding a suite

1. Create `cli/tests/<area>.test.nu` defining `def "<area>-tests" [] { [ { name, run }, ... ] }`.
2. `source` it in `run.nu` and add `{ name: "<area>", tests: (<area>-tests) }` to the `suites` list.
