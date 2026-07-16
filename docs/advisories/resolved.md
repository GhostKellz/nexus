# Resolved advisories

Issues from [accepted.md](accepted.md) move here once fixed, with the resolving
version/commit and the verification evidence used to confirm the fix.

| ID | Area | Issue | Resolved by | Date | Verification |
|----|------|-------|-------------|------|--------------|
| NX-001 | TLS | Peer/certificate verification was a no-op that accepted any certificate. | v0.1.2 stabilization | 2026-07 | `ensurePeerVerified()` now fails closed: when `verify_peer` is set (the default) the handshake returns `error.PeerVerificationUnavailable` instead of accepting an unauthenticated peer (`src/stdlib/net/tls.zig`). Regression test asserts the refusal. Verification is still not *implemented* — see NX-014. |
| NX-002 | ACME | Order finalize / certificate download fabricated success without completing against a CA. | v0.1.2 stabilization | 2026-07 | `finalizeOrder()` / `downloadCertificate()` return `error.AcmeNotImplemented` rather than reporting a fake success (`src/stdlib/net/acme.zig`); tests assert the fail-closed path. Completing the flow is deferred — see NX-015. |
| NX-003 | WASM policy | `checkFsRead`/`checkFsWrite` used string-prefix matching that `..`/prefix-siblings could escape. | v0.1.2 stabilization | 2026-07 | Replaced with lexical component-wise normalization (`normalizeAbsolute`, `src/wasm/policy.zig`); a test rejects the `/allowed-evil` prefix-sibling escape and `..` traversal. |
| NX-004 | Static files | Path confinement was a substring `".."` check, not canonical containment. | v0.1.2 stabilization | 2026-07 | `resolveStaticPath()` now normalizes lexically (`src/stdlib/net/static.zig`); a test rejects percent-encoded `%2e%2e` traversal above the base. |
| NX-005 | Middleware | The chain did not thread a real `next()`; ordering/short-circuit were unreliable. | v0.1.2 stabilization | 2026-07 | `Chain.next()` advances a cursor through the middleware slice, runs each once, and short-circuits reliably (`src/stdlib/net/http.zig`). |
| NX-006 | WASM interpreter | Many opcodes/call paths logged instead of executing; results were silently wrong. | v0.1.2 stabilization | 2026-07 | `.call`/`.call_indirect` return `error.UnsupportedCall`/`UnsupportedIndirectCall` and the dispatch `else` returns `error.UnimplementedOpcode` — no opcode is skipped (`src/wasm/interpreter.zig`). A 21-test conformance + fail-closed battery pins the behavior. |
| NX-007 | WASI | Host-function registration populated placeholders reporting false success. | v0.1.2 stabilization | 2026-07 | `registerAll()` returns `error.WasiRegistrationUnsupported` instead of wiring fake imports (`src/wasm/wasi.zig`); the host-side arg/env serialization and fd-allocation logic are implemented and unit-tested. Guest-reachable end-to-end WASI is deferred — see NX-016. |
| NX-008 | CLI | `nexus test` printed "not yet implemented" and exited 0 — a false positive in CI. | v0.1.2 stabilization | 2026-07 | `nexus test` returns `error.UnsupportedCommand` (nonzero exit) pointing at `zig build test` (`src/main.zig`). Likewise `nexus run <.wasm>`/`<.wat>` fail closed instead of faking a run. |
| NX-009 | CLI scaffold | `nexus init` generated `server.get(...)`, a per-verb helper that is not in the API (`route(method, path, handler)`), so the emitted project did not compile. | v0.1.2 stabilization | 2026-07 | The generator now emits `server.route("GET", …)` (`src/scaffold.zig`). Gated by the `init-contract` build step, which generates a project, child-builds it against this checkout, launches it on an ephemeral port, and asserts a live response — proving the scaffold compiles and runs (`zig build init-contract`). |
| NX-010 | Streams | Stream callbacks referenced function-local `undefined`/static pointers and could crash; concurrent pipes clobbered each other's destination. | v0.1.2 stabilization | 2026-07 | Callbacks now take an explicit caller-owned `context: ?*anyopaque`; writable streams optionally own heap context freed on `deinit` (`owned_context`/`owned_context_free`). The ownership contract is documented in the `stream.zig` module block. A regression test runs two independent concurrent pipelines and asserts they do not clobber each other's context (`src/stdlib/stream/stream.zig`). |
| NX-013 | Performance claims | Historical "10x faster / 500k rps / ~5 MB / reimagined" marketing figures appeared in source comments, the CLI (`nexus --version`), `README.md`, examples, and the benchmark's "Expected Results" — all aspirational and unmeasured. | v0.1.2 stabilization | 2026-07 | Every unmeasured figure was removed from `src/main.zig`, the examples, `README.md`, and the docs; the throughput benchmark is now an honest load-test **target** server that emits no numbers of its own (`benchmarks/http_throughput.zig`). A tree-wide scan (`git grep` for `10x`/`500k`/`reimagined`/`Expected Results`) returns no remaining claims. |

## Adding an entry

When you close an accepted risk:

1. Remove the row from [accepted.md](accepted.md).
2. Add a row here with the commit/tag that fixed it.
3. Record how it was verified — the exact command and observed result
   (e.g. `zig build test` output, a reproducing program that now behaves
   correctly, or a protocol interop check).
