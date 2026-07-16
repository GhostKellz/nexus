# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While Nexus is pre-1.0, minor/patch bumps may include breaking API changes.

## [0.1.2] — 2026-07-16

Stabilization release: restore compatibility with the pinned Zig
`0.17.0-dev` toolchain, remove crash/leak classes, and honestly gate
experimental subsystems.

### Security

Fail-closed hardening — previously-silent unsafe paths now refuse rather than
fake success. Each item is tracked with verification evidence in
[`docs/advisories/resolved.md`](docs/advisories/resolved.md).

- **TLS (NX-001):** peer/certificate verification no longer accepts any
  certificate. With `verify_peer` (the default) the handshake fails closed with
  `error.PeerVerificationUnavailable`. (Real verification is still unimplemented
  — see NX-014.)
- **ACME (NX-002):** order finalize / certificate download return
  `error.AcmeNotImplemented` instead of fabricating success (see NX-015).
- **WASM capability policy (NX-003):** filesystem checks now normalize paths
  component-wise (`normalizeAbsolute`), rejecting `..` traversal and
  prefix-sibling escapes instead of string-prefix matching.
- **Static files (NX-004):** path confinement resolves lexically and rejects
  percent-encoded (`%2e%2e`) traversal above the served root.
- **WASM interpreter (NX-006):** unsupported opcodes/calls fail closed
  (`error.UnimplementedOpcode` / `error.UnsupportedCall`) rather than logging
  and continuing with silently-wrong results.
- **WASI (NX-007):** host-function registration fails closed
  (`error.WasiRegistrationUnsupported`) instead of wiring placeholder imports
  that reported false success.
- **CLI (NX-008):** `nexus test` exits nonzero (`error.UnsupportedCommand`)
  instead of printing "not yet implemented" and exiting 0; `nexus run` on
  `.wasm`/`.wat` fails closed rather than faking a run.
- **ZIM package client:** install/search/remove/list/update-index operations
  return `error.PackageOperationUnavailable` instead of simulating success, so
  no caller can mistake an unimplemented package pipeline for a real one.

### Fixed

- **CLI scaffold (NX-009):** `nexus init` emitted `server.get(...)`, a per-verb
  helper that is not in the API, so generated projects did not compile. The
  generator (`src/scaffold.zig`) now emits `server.route("GET", …)`. Gated by the
  `init-contract` build step, which generates a project, child-builds it against
  this checkout, launches it on an ephemeral port, and asserts a live response.
- **Middleware (NX-005):** the chain now threads a real `next()` — a cursor
  advances through the middleware slice, running each once with reliable
  ordering and short-circuiting.
- **Streams (NX-010):** callbacks take an explicit caller-owned context instead
  of dangling function-local pointers; writable streams optionally own and free
  heap context on `deinit`, and concurrent pipes no longer clobber each other.
- Corrected a WASM `memory.size` double page-division that reported the wrong
  size.

### Changed

- Bumped package version to `0.1.2` and `minimum_zig_version` to the pinned
  `0.17.0-dev.1413+addc3c3b8` toolchain in `build.zig.zon`. `build.zig` now
  asserts the running compiler matches this exact revision and fails with an
  actionable message otherwise.
- **Version single-sourced:** the `nexus` CLI and the OpenTelemetry SDK report
  string now read the version from `build.zig.zon` via `build_options` instead
  of hardcoding `0.1.0`.
- **Public API forced to compile:** `root.zig` now uses `refAllDeclsRecursive`,
  compiling every public method body so removed-Zig-API calls in public paths
  (e.g. `std.fs.cwd`, `std.time.nanoTimestamp`, unmanaged `ArrayList.init`)
  surface at build time instead of hiding behind lazy analysis; fixed the ones
  this exposed during the `std.Io` migration.
- Restructured documentation to the house layout: single `docs/README.md`
  index, `getting-started/`, `guides/`, `reference/`, `internals/`, and
  `advisories/`, with mermaid diagrams documenting the real code.
- Rewrote `README.md` to be evidence-based: removed unsupported performance
  claims and split the capability status into the exported public surface vs.
  in-tree-but-unexported subsystems.
- **API surface narrowed (compatibility):** `@import("nexus")` now exports only
  the supported namespaces. The experimental in-tree subsystems (HTTP/2, HTTP/3,
  QUIC, gRPC, GraphQL, the custom TLS transport, ACME, the ZIM package client,
  OpenTelemetry, the `db` drivers, and the Wasmer-style layer) are no longer part
  of the public surface; a `root.zig` test asserts their absence so they cannot
  be re-exported by accident. Most remain in-tree and unit-tested; the `db`
  drivers (PostgreSQL/Redis) are gated more strongly — removed from the build and
  the test tree as well, because they do not compile under the pinned toolchain
  (NX-011). The `database_demo` example was removed with them.

### Added

- `SECURITY.md`, `CONTRIBUTING.md`, and `.github/` issue templates.
- `docs/advisories/` tracking accepted risks (NX-011, NX-012, NX-014..NX-017,
  NX-019) and resolved issues (NX-001..NX-010, NX-013), with verification
  evidence.
- Fail-closed regression tests and a WASM interpreter conformance + fail-closed
  battery pinning the security behavior above.
- Socket/process integration contracts (`tests/init_contract.zig`,
  `tests/cli_contract.zig`) that exercise the generated `nexus init` project and
  the CLI end to end, wired as the `init-contract`, `test-contracts`, `test-all`,
  and `release` build steps.

### Removed

- Stray committed `test_std` binary and legacy uppercase docs
  (`docs/ARCHITECTURE.md`, `docs/GETTING_STARTED.md`, root `SPEC.md` /
  `QUICKSTART.md` / `ARCHITECTURE.md`), and the stale `RELEASE_NOTES_v0.3.0.md`.
- The discontinued, unmaintained ZigScript subsystem (`src/zigscript/`, the
  `nexus-zs` binary and its `zs` build step, and the ZigScript host/loader
  tests) is dropped entirely; its `http_get` host-call advisory (NX-018) is
  retired with it.
- The ownership-broken `wasm.load` convenience wrapper — a `Module` is owned by
  the `Engine` that created it, so use `engine.loadModule(io, path)` instead.

### Known issues

- The WASM engine has **no binary/`.wat` parser** (`Module.instantiate` fails
  closed with `error.WasmParsingUnsupported`), so no `.wasm`/`.wat` module can
  be instantiated or run; the interpreter executes only a raw MVP-opcode subset
  (NX-016, NX-017).
- TLS peer verification and the ACME issuance flow are unimplemented (they fail
  closed rather than complete). gRPC and QUIC/HTTP/3 remain experimental. The
  `db` drivers do not compile under the pinned toolchain and are gated out of the
  surface, build, and tests entirely (NX-011). See the README capability status
  and `docs/advisories/accepted.md`.

## [0.1.1] — 2026-05-05

### Fixed

- Compatibility with newer Zig `0.16.0-dev` / `0.17.0-dev` toolchains:
  `PriorityQueue` and `posix` API updates, and time-API changes.

### Removed

- CI workflow (builds and tests are run locally against the pinned toolchain).

## [0.1.0] — 2025-11-17

Initial implementation of the runtime and standard library scaffolding.

### Added

- **Runtime** — event loop with epoll/kqueue/IOCP backends and a work-stealing
  scheduler; development hot reload.
- **Module system** — `.zig` / `.wasm` resolution with content-addressed
  caching.
- **HTTP** — HTTP/1.1 server and client, routing, static file serving, and an
  Express-style middleware layer (logger, CORS, compression, body parser, auth).
- **Protocols** — initial HTTP/2 (HPACK/Huffman), WebSocket, gRPC, and
  QUIC/HTTP/3 modules.
- **WASM** — WebAssembly engine/interpreter, WASI preview1 host surface, and a
  capability-based security policy.
- **Standard library** — `fs`, `net`, `stream`, `console` modules.
- **Data** — PostgreSQL and Redis driver modules.
- **Security/networking** — custom TLS 1.2/1.3 and ACME/Let's Encrypt modules.
- **Tooling** — `nexus` CLI (`init`, `run`, `dev`, `build`, `serve`, …), ZIM
  package client, and OpenTelemetry hooks.

> Many of these subsystems were introduced as partial or experimental
> implementations. See the README capability status for their current state.

[0.1.2]: https://github.com/ghostkellz/nexus/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/ghostkellz/nexus/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/ghostkellz/nexus/releases/tag/v0.1.0
