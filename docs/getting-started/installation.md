# Installation

Nexus is built from source with the Zig toolchain. There are no third-party
dependencies to fetch — the package's `dependencies` table in
[`build.zig.zon`](../../build.zig.zon) is intentionally empty.

## Toolchain

Nexus tracks a **single pinned Zig development build**. Use the exact version in
`minimum_zig_version` in [`build.zig.zon`](../../build.zig.zon). Other Zig
versions — including newer nightlies and tagged releases — are **not supported**
and will usually fail to compile, because Nexus follows the evolving `std.Io`
API.

Check your Zig version:

```bash
zig version
```

If it does not match `minimum_zig_version`, install the matching build from the
[Zig downloads](https://ziglang.org/download/) page (or your version manager)
before continuing.

## Build from source

```bash
git clone https://github.com/ghostkellz/nexus.git
cd nexus
zig build
```

The CLI is produced at `./zig-out/bin/nexus`:

```bash
./zig-out/bin/nexus --version
```

To put it on your `PATH`, symlink or copy it, e.g.:

```bash
ln -s "$PWD/zig-out/bin/nexus" ~/.local/bin/nexus
```

## Running the tests

```bash
zig build test
```

Tests run against the pinned toolchain. See [CONTRIBUTING.md](../../CONTRIBUTING.md)
for the full local check (`zig fmt`, Debug/ReleaseSafe).

## Using Nexus as a library

To depend on the `nexus` module from another Zig project, add it as a module in
your `build.zig` and import it as `@import("nexus")`. The public API is defined
in [`src/root.zig`](../../src/root.zig); see [reference/api.md](../reference/api.md).

```zig
const nexus_mod = b.addModule("nexus", .{
    .root_source_file = b.path("path/to/nexus/src/root.zig"),
});
exe.root_module.addImport("nexus", nexus_mod);
```

> The APIs are unstable while Nexus is pre-1.0; pin to a specific commit.

## Next steps

- [quickstart.md](quickstart.md) — build and run your first server.
- [configuration.md](configuration.md) — server and project configuration.
