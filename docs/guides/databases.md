# Databases

> **Status: 🔴 gated out.** The PostgreSQL and Redis drivers are **not
> available** in this release. They are removed from the public surface
> (`nexus.db` does not exist), from the build, and from the test tree, because
> they contain multiple removed-std-API calls and do not compile under the
> pinned toolchain. `root.zig` asserts their absence. See NX-011 in
> [../advisories/accepted.md](../advisories/accepted.md) and the
> [capability status](../README.md#capability-status).

There is no supported database API in v0.1.x. The driver sources remain in-tree
as scaffolding (`src/stdlib/db/`) but carry no compile or test guarantee.

## Planned

Per NX-011, the drivers are slated to return no earlier than **v0.2**, after the
`std.Io` migration lands and they are re-exported with a real pool lifecycle, a
vetted TLS/auth path (real TLS still fails closed — see NX-014), and interop
tests. Until that boundary clears, do not rely on `nexus.db`.

## Related

- [reference/api.md](../reference/api.md) — the exported public surface (no `db`).
- [../advisories/accepted.md](../advisories/accepted.md) — NX-011 rationale.
