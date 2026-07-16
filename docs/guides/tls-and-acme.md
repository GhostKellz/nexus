# TLS and ACME

> **Status: 🔴 experimental.** TLS peer/certificate verification and the ACME
> finalize/download flow are **not implemented**. They now **fail closed** —
> they refuse rather than silently accepting an unverified peer or faking a
> certificate — so they cannot be used to secure real traffic yet. See
> [advisories/accepted.md](../advisories/accepted.md) (NX-014, NX-015).

## What exists

- A TLS 1.2/1.3 handshake code path. Peer/certificate verification is **not
  implemented**: with `verify_peer` set (the default) the handshake fails closed
  with `error.PeerVerificationUnavailable` rather than accepting any certificate
  (`tls.zig`). It no longer silently trusts an unauthenticated peer (NX-001,
  [resolved](../advisories/resolved.md)), but it also cannot complete a verified
  connection.
- An ACME/Let's Encrypt client skeleton whose order finalize and certificate
  download return `error.AcmeNotImplemented` (`acme.zig`) instead of reporting a
  fake success (NX-002, [resolved](../advisories/resolved.md)).

## What this means

- The built-in TLS cannot terminate a verified connection — do not put it in
  front of anything that carries real data.
- ACME cannot obtain or renew certificates — the flow does not complete against
  a real CA.
- For real TLS termination, front Nexus with a proven reverse proxy (nginx,
  Caddy) until these subsystems are implemented and audited.

## Tracking

Completing peer verification and the ACME flow are known priorities. Progress
and any resolution will be recorded in
[advisories/resolved.md](../advisories/resolved.md).
