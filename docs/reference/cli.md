# CLI reference

Every `nexus` command and its **real** current behavior. The CLI entry point is
[`src/main.zig`](../../src/main.zig).

> **Status: 🟡 partial.** `run` (`.zig` only), `dev`, and `serve` are functional.
> `build` is a thin wrapper; `deploy`, `test`, and `.wasm`/`.wat` execution
> **fail closed** with a nonzero exit rather than faking success — see below.

## Synopsis

```bash
nexus <command> [args]
```

## Commands

| Command | Status | Behavior |
|---------|--------|----------|
| `nexus init [name]` | 🟡 partial | Scaffolds a project directory (see below). The generated `main.zig`/`build.zig` target an older API shape and need adapting. |
| `nexus run <file>` | 🟢 `.zig` only | Dispatches by extension: `.zig` → `zig run` subprocess (the only path that executes). `.wasm` → `error.UnsupportedWasmExecution`; `.wat` → `error.UnsupportedFileType` — both **fail closed** (no parser exists). |
| `nexus dev [port]` | 🟢 works | Watches `src/` and `examples/`, rebuilds and restarts `zig-out/bin/nexus serve`. Positional `port` (default `3000`). |
| `nexus serve` | 🟢 works | Runs a built-in demo HTTP server on port `3000` (`GET /`, `GET /api/status`). |
| `nexus build [--release]` | 🟡 partial | Wraps `zig build`; not a full pipeline. |
| `nexus deploy [target]` | 🟠 stub | Prints "deployment not fully implemented" — does nothing. |
| `nexus test` | 🔴 fails closed | Returns `error.UnsupportedCommand` (**nonzero exit**) and points at `zig build test`. It does **not** run the suite, but it will not pass silently. |
| `nexus version` / `--version` | 🟢 works | Prints the version banner. |
| `nexus help` / `--help` | 🟢 works | Prints usage. |

## `nexus run`

```bash
nexus run examples/hello-world.zig   # compiles & runs via `zig run`
nexus run module.wasm                # fails closed: error.UnsupportedWasmExecution
nexus run module.wat                 # fails closed: error.UnsupportedFileType
```

Only `.zig` files execute — they are run by spawning `zig run` as a subprocess,
so they compile against your installed toolchain. `.wasm` and `.wat` inputs are
read and their magic is validated, but the engine has no binary/`.wat` parser
(`Module.instantiate` returns `error.WasmParsingUnsupported`), so both exit
nonzero rather than pretending to run. See [advisories](../advisories/accepted.md)
NX-017.

## `nexus dev`

```bash
nexus dev            # port 3000
nexus dev 8080       # positional port
```

Watches source directories and restarts on change.

## `nexus init`

Scaffolds:

```
<name>/
├── src/main.zig      # generated HTTP server entry point
├── static/
├── tests/
├── build.zig
└── README.md
```

> The generated `main.zig` uses `server.get(...)`, which does not exist in the
> current API — treat the scaffold as a starting point and adapt it to
> [api.md](api.md).

## Notes on `nexus test`

`nexus test` returns `error.UnsupportedCommand` and exits **nonzero**, so it can
never be a false-positive CI gate. It does not run the suite itself; run the real
suite with:

```bash
zig build test
```
