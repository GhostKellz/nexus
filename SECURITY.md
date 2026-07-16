# Security Policy

Nexus is **experimental, pre-1.0 software**. Several subsystems are incomplete
or scaffolding, and the runtime currently has known security limitations that
make it unsuitable for production or untrusted workloads. This document explains
how to report issues and what is (and is not) currently protected.

## Reporting a vulnerability

**Do not open public GitHub issues for security reports.**

Report privately using GitHub's
[private vulnerability reporting](https://github.com/ghostkellz/nexus/security/advisories/new)
("Report a vulnerability" under the repository **Security** tab). If that is
unavailable, contact the maintainers at CK Technology LLC directly.

Please include:

- affected component/module and commit hash,
- a minimal reproduction (source, module, or request),
- the impact you observed and the toolchain/OS used.

Because this is a volunteer, pre-release project, there is no guaranteed
response SLA. Coordinated disclosure is appreciated — give maintainers a
reasonable window before any public write-up.

## Supported versions

Only the tip of `main`, built with the pinned Zig toolchain in
[`build.zig.zon`](build.zig.zon), receives fixes. Tagged pre-1.0 releases are
not separately maintained.

| Version | Supported |
|---------|-----------|
| `main` (pinned Zig dev toolchain) | ✅ |
| `v0.1.x` tags | ❌ (upgrade to `main`) |
| Any other Zig toolchain | ❌ (unsupported) |

## Known limitations (do not rely on these paths)

These are documented, accepted-for-now weaknesses tracked in
[docs/advisories/accepted.md](docs/advisories/accepted.md). They are not secret
and are not yet fixed:

- **TLS (experimental custom transport)** — real certificate-chain/hostname
  verification against a trust store is **not implemented**. The handshake now
  fails closed: with `verify_peer` set (the default) it returns
  `error.PeerVerificationUnavailable` rather than accepting an unauthenticated
  peer, so it never silently trusts a certificate — but it also cannot complete
  a verified outbound handshake, so the custom path must not be relied on for
  confidentiality or authentication (NX-014). The default HTTPS client wraps the
  Zig standard-library TLS stack (`std.http.Client`), which does verify peers.
- **ACME / Let's Encrypt** — order finalize/download are not implemented and
  fail closed (`error.AcmeNotImplemented`); it must not be used to obtain or
  manage real certificates (NX-015).
- **WASM / WASI** — there is no WASM binary parser and no guest import wiring;
  `Module.instantiate` and WASI registration fail closed. Real guest execution
  is out of scope for this release, so untrusted modules are **not** run at all
  rather than run unsafely (NX-016, NX-017).
- **Capability policy** — filesystem/network confinement normalizes paths
  lexically (component-wise), rejecting `..`, prefix-sibling, and duplicate-
  separator escapes (NX-003, NX-004). It does **not** yet resolve symlinks, so
  symlink-based escapes remain out of scope until post-`open()` realpath
  confinement lands.
- **HTTP request framing** — parsing is hardened against conflicting/duplicate
  `Content-Length`, `Transfer-Encoding` smuggling, oversized header
  names/values/bodies, truncated bodies, obsolete line folding, and malformed
  request lines, each pinned by a negative test. The wider server surface
  (timeouts, backpressure, connection lifecycle) is still experimental — do not
  expose it to untrusted clients.
- **Database drivers** — PostgreSQL/Redis drivers are gated out of the public
  surface, the build, and the test tree; they do not compile under the pinned
  toolchain and are unhardened (no vetted TLS/auth path). Not usable in this
  release (NX-011).

## Trust / privilege model (intended)

| Component | Runs with | Notes |
|-----------|-----------|-------|
| Native Zig modules (`.zig`) | Full host privileges | Trusted code; no sandbox |
| WASM modules (`.wasm`) | Restricted by `wasm.WasmPolicy` | Capability-gated (experimental) |
| CLI (`nexus`) | Invoking user's privileges | No privilege elevation |

Nexus does not require or request elevated privileges. Run it as an
unprivileged user.

## Auditing your build

Nexus has **zero third-party dependencies** (see the empty `dependencies` block
in [`build.zig.zon`](build.zig.zon)), so the supply-chain surface is the Zig
toolchain plus this repository. To reproduce a clean build and test:

```bash
zig build                 # from a clean .zig-cache
zig build test            # unit/integration tests
```

Verify the toolchain matches `minimum_zig_version` in `build.zig.zon` before
trusting a build.
