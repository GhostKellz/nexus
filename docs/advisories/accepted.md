# Accepted risks and known limitations

Nexus is experimental, pre-1.0 software. The items below are **known** and
**accepted for the current phase** — they are documented rather than hidden.
None of these subsystems should be trusted with real traffic, data, or secrets.
Fixes move to [resolved.md](resolved.md) with verification evidence.

**Owner:** the Nexus maintainers (CK Technology LLC) own every item below.
**Gate:** most accepted items are enforced by a fail-closed check with a
regression test, cross-referenced to its `NX-00x` entry in
[resolved.md](resolved.md); such an item is never treated as safe merely because
no caller currently reaches it. Some items are gated even more strongly by being
kept off the public surface and out of the build entirely — the database drivers
(NX-011), which do not compile against the pinned toolchain. The **Boundary**
column records the release/prereq gate that must clear before an item may be
enabled or relied on.

| ID | Area | Severity | Boundary (enable only when…) | Description | Source |
|----|------|----------|------------------------------|-------------|--------|
| NX-011 | db drivers | Medium | ≥ v0.2; migrate to the pinned toolchain, then re-export with pool lifecycle + vetted TLS/auth path and interop tests | PostgreSQL/Redis drivers are **gated out of the public surface, the build, and the test tree** (removed from `nexus.db`/`root.zig`; excluded from the aggregate `test {}`; not built as an example). They contain multiple removed-std-API calls under the pinned toolchain and do not compile; keeping them exported would be fiction. The `db` absence is asserted by the "experimental subsystems are not part of the default public surface" test in `src/root.zig`. The sources remain in-tree as scaffolding but carry no compile/test guarantee until the boundary above clears; they are also unhardened (incomplete pool lifecycle/error paths, unvetted TLS/auth — real TLS still fails closed, see NX-014). | `src/stdlib/db/`, `src/root.zig` |
| NX-012 | HTTP/2, gRPC, QUIC/HTTP3 | Medium | ≥ v0.2; behind an explicit experimental opt-in with end-to-end interop verification | Present as scaffolding; not interop-verified and not real end-to-end. | `src/stdlib/net/` |
| NX-014 | TLS | High | Certificate-chain + hostname verification against a trust store is implemented and tested | Peer/certificate verification is not **implemented**. The handshake now fails closed (see NX-001 in [resolved.md](resolved.md)) rather than accepting any cert, so no unauthenticated peer is trusted — but real verification against a trust store is still absent, so outbound TLS with `verify_peer` cannot complete. | `src/stdlib/net/tls.zig` |
| NX-015 | ACME | Medium | The finalize/download flow completes against a real CA (staging first) with tests | The ACME order finalize / certificate download flow is not implemented. It fails closed (see NX-002 in [resolved.md](resolved.md)) instead of faking success, so certificate issuance does not complete against a real CA. | `src/stdlib/net/acme.zig` |
| NX-016 | WASI | Medium | A WASM binary parser + import wiring land together with guest-reachable preview1 tests | End-to-end guest-reachable WASI is absent. Host-side arg/env serialization and descriptor allocation are implemented and tested, but there is no WASM binary parser or import wiring, so a guest module cannot call preview1 (registration fails closed — see NX-007 in [resolved.md](resolved.md)). | `src/wasm/wasi.zig`, `src/wasm/interpreter.zig` |
| NX-017 | WASM engine | Medium | A binary/`.wat` parser, memory model, and execution limits land with end-to-end guest tests | There is no WASM binary/`.wat` parser; `Module.instantiate` fails closed with `error.WasmParsingUnsupported`. The interpreter executes only a raw MVP-opcode subset and fails closed on unsupported opcodes/calls (see NX-006 in [resolved.md](resolved.md)). `nexus run` only executes `.zig`; `.wasm`/`.wat` inputs fail closed. | `src/wasm/engine.zig`, `src/wasm/interpreter.zig` |
| NX-019 | Static files | Medium | Post-`open()` realpath confinement lands with static file I/O and a symlink-escape regression test | `resolveStaticPath` confines the served path **lexically** only (percent-decode + component normalization, rejecting `..` escapes — see NX-004 in [resolved.md](resolved.md)). It does **not** resolve symlinks, so a symlink beneath the served root that points outside it would not be caught by the lexical check. The symlink confinement is meant to be applied after `open()` via realpath when static file I/O is restored; until then, do not serve a root whose contents an attacker can influence with symlinks. | `src/stdlib/net/static.zig` |

## Review

When an item is remediated, it is moved to [resolved.md](resolved.md) with the
fixing commit and verification steps. See [triage.md](triage.md) for how new
issues are handled.
