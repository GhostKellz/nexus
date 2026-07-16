# WASM modules

> **Status: 🟠 experimental — fails closed.** There is **no WASM binary/`.wat`
> parser**: `Module.instantiate` returns `error.WasmParsingUnsupported`, so a
> module file cannot be instantiated or run today. The interpreter executes only
> a raw MVP-opcode subset and **fails closed** (`error.UnimplementedOpcode` /
> `error.UnsupportedCall`) on anything it does not implement — it never silently
> logs-and-continues. The capability policy now uses component-wise path
> normalization (path-traversal is rejected). Do not treat any of this as a
> production sandbox. See [internals/wasm-runtime.md](../internals/wasm-runtime.md)
> and [advisories/accepted.md](../advisories/accepted.md) (NX-016, NX-017).

## Loading a module

The `wasm` module exposes `Engine`, `Module`, `Instance`, `Memory`, `Value`,
`WasiContext`, `WasiHost`, and the policy types. A `Module` is owned by the
`Engine` that created it, so you construct an `Engine`, call
`engine.loadModule(io, path)`, and `engine.deinit()` when done. `loadModule`
reads the file and constructs a `Module`, but `Module.instantiate` fails closed
with `error.WasmParsingUnsupported` until a binary parser exists — so there is no
supported end-to-end "load and run a `.wasm`" path yet.

The CLI reflects this — both WASM inputs fail closed with a nonzero exit:

```bash
nexus run module.wasm    # error.UnsupportedWasmExecution (no parser)
nexus run module.wat     # error.UnsupportedFileType (no in-tree wat2wasm)
```

## Capability policy

Execution is governed by `WasmPolicy`. A policy decides filesystem, network,
environment, memory, and CPU-time access:

| Check | Method |
|-------|--------|
| Network connect | `checkNet(...)` |
| Filesystem read | `checkFsRead(path)` |
| Filesystem write | `checkFsWrite(path)` |
| Environment read | `checkEnv(name)` |
| Memory limit | `checkMemory(bytes)` |
| CPU-time limit | `checkCpuTime(...)` |

Construct a policy with one of:

- `WasmPolicy.restrictive(...)` — deny by default.
- `WasmPolicy.permissive(...)` — allow by default.
- `WasmPolicy.fromConfig(...)` — build from a `PolicyConfig` (`FsPolicy`,
  `NetRule`, limits).

```zig
var policy = nexus.wasm.WasmPolicy.restrictive(allocator);
defer policy.deinit();
```

> **Path confinement:** filesystem checks normalize paths component-wise
> (`normalizeAbsolute` in `policy.zig`) and reject `..` traversal and
> prefix-sibling escapes (e.g. `/allowed-evil` against an `/allowed` root); a
> regression test pins this (NX-003, [resolved](../advisories/resolved.md)).
> Symlink resolution is still lexical, not `realpath`-based, and — because there
> is no parser — no guest can reach these checks yet. Do not rely on this as a
> sandbox for hostile code.

## Related

- [internals/wasm-runtime.md](../internals/wasm-runtime.md) — engine, WASI, policy internals.
- [internals/module-system.md](../internals/module-system.md) — resolution and caching.
