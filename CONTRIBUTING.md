# Contributing to Nexus

Thanks for your interest in Nexus. It is an early-stage, experimental runtime,
so contributions that improve correctness, memory safety, and honesty of the
codebase are especially valuable.

## Before you start

- Read the [capability status](README.md#capability-status) matrix — it shows
  what is real, partial, or experimental.
- Nexus builds against the **exact** pinned Zig dev toolchain in
  [`build.zig.zon`](build.zig.zon) (`minimum_zig_version`). Install that version;
  other Zig versions are not supported.
- Nexus has **no third-party dependencies** — keep it that way unless there is a
  strong, discussed reason to add one.

## Development workflow

1. Fork and branch from `main` (`feature/…`, `fix/…`, or `docs/…`).
2. Make focused changes — the smallest change that solves the problem. Keep
   unrelated refactors in separate PRs.
3. Add or update tests next to the code you change. Tests are Zig-native and
   deterministic: unit tests live beside the code, network tests bind an
   ephemeral loopback port (`.port = 0`) and read it back with `boundPort()`,
   and end-to-end coverage goes through the contract tests under `tests/`.
4. Run the local checks (below) before opening a PR.
5. Open a PR describing **what** changed and **why**, and update the capability
   status / docs if behavior changed.

## Local checks

The test suite is split into explicit steps so the inner dev loop stays fast and
the full suite is one command:

```bash
zig fmt --check build.zig src tests examples benchmarks

zig build test-lib        # fast: library unit tests only (src/root.zig)
zig build test            # all in-process unit roots (lib + exe + integration)
zig build test-contracts  # socket/process integration (nexus init build + CLI matrix)
zig build test-all        # complete release suite = test + test-contracts
```

Run `zig build test-lib` on every change (the fast loop) and `zig build test-all`
before pushing; run the release-critical steps under `-Doptimize=ReleaseSafe`
too. `test-lib` is a single compiler process (bounded memory, a few seconds for
the ~290 library tests). The aggregate steps (`test`, `test-all`) compile several
test roots at once, so on a memory-constrained machine prefer the individual
steps (`test-lib`, `init-contract`, `cli-contract`) or cap parallelism with
`zig build test-all -j1` to avoid the kernel OOM-killing parallel compiles.

Do not mark work complete while tests fail, leak (`std.testing.allocator`
reports), panic, or hang. Do not weaken assertions or delete tests to make a
build pass — record the failure instead.

## Code style

- Format all Zig with `zig fmt`; keep the tree formatter-clean.
- Follow existing naming and module conventions; no `_v2`/`_new` suffixes.
- Comments explain **why**, not **what**. No static version numbers in comments —
  point at the source of truth (`build.zig.zon`).
- Be explicit about ownership: every allocation needs a clear owner and an
  `errdefer` on partial-init paths. Avoid `catch {}` — propagate, log with
  context, or document why the error is safely ignorable.
- Do not claim a capability works if it is a placeholder. Gate experimental
  features and mark them honestly.

## Temp files in tests

Tests that need files on disk must use `std.testing.tmpDir(.{})`, which creates a
per-test directory under `.zig-cache/tmp` and is removed by `tmp.cleanup()`. Let
Zig's cache manage scratch space — do not hand-roll temp paths under `/tmp` or a
project-local scratch directory, and do not leave artifacts behind. Strings fed
to lexical policy checks (`checkFs*`, `checkNet`) are never touched on disk; use
neutral fictional paths like `/sandbox/...` so they don't read as real files.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(optional scope): <description>

feat(http): add chunked transfer encoding
fix(wasm): reject out-of-bounds memory access
docs(readme): correct capability status
refactor(scheduler): simplify worker shutdown
```

Common types: `feat`, `fix`, `docs`, `refactor`, `test`, `perf`, `build`,
`chore`. Keep the subject imperative and under ~72 characters.

## Reporting bugs & security issues

- Bugs: open an issue using the templates in
  [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE).
- Security vulnerabilities: **do not** file a public issue — follow
  [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
