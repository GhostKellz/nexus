const std = @import("std");
const builtin = @import("builtin");

// Nexus follows the still-evolving `std.Io` API and therefore pins one exact Zig
// development build. Enforce it while the build graph is constructed so a
// mismatched toolchain fails immediately with an actionable message instead of a
// wall of downstream std-library compile errors. The pinned revision lives in
// build.zig.zon (single source of truth); SemanticVersion ordering ignores only
// the trailing "+<commit>" build metadata, so the `dev.<N>` counter is the pin.
comptime {
    const pinned = std.SemanticVersion.parse(@import("build.zig.zon").minimum_zig_version) catch
        @compileError("build.zig.zon has an unparseable minimum_zig_version");
    if (builtin.zig_version.order(pinned) != .eq) {
        @compileError(
            "Nexus requires the exact pinned Zig toolchain " ++
                @import("build.zig.zon").minimum_zig_version ++
                " declared in build.zig.zon. Run `zig version`, then install the matching build (https://ziglang.org/download/); other Zig versions are not supported.",
        );
    }
}

// `build` mutates the build graph (`b`); the external runner executes it.
pub fn build(b: *std.Build) void {
    // Native by default; caller may cross-compile and pick the optimize mode.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Experimental, UNVERIFIED custom TLS transport. The bundled TLS stack does
    // not implement peer/certificate verification, transcript verification, the
    // key schedule, or AEAD record protection, so it is inaccessible by default
    // and is never presented as a secure channel. Opt in explicitly to exercise
    // it; production paths must not rely on it in v0.1.2.
    const tls_experimental = b.option(
        bool,
        "tls-experimental",
        "Enable the experimental, UNVERIFIED custom TLS transport (insecure; off by default)",
    ) orelse false;

    // Single source of truth for the release version and supported toolchain:
    // the package manifest. Every binary, `--version` string, generated project,
    // and package metadata field derives from these so they cannot drift apart.
    const manifest = @import("build.zig.zon");

    const build_options = b.addOptions();
    build_options.addOption(bool, "tls_experimental", tls_experimental);
    build_options.addOption([]const u8, "version", manifest.version);
    build_options.addOption([]const u8, "min_zig_version", manifest.minimum_zig_version);
    const options_module = build_options.createModule();

    // The public library module consumers import as `nexus`. Its public surface
    // is whatever `src/root.zig` re-exports.
    const mod = b.addModule("nexus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Expose compile-time build options (e.g. the experimental-TLS gate) to the
    // library sources. Every executable, test, example, and benchmark imports
    // `nexus`, so wiring the options module here reaches all of them.
    mod.addImport("build_options", options_module);

    // Project scaffolding used by `nexus init`. Kept as its own module so the
    // CLI and the generated-project contract test share one generator.
    const scaffold_mod = b.createModule(.{
        .root_source_file = b.path("src/scaffold.zig"),
        .target = target,
    });
    scaffold_mod.addImport("build_options", options_module);

    // The `nexus` CLI — the one binary installed by the default `zig build` and
    // the only supported/shipped executable in v0.1.2.
    const exe = b.addExecutable(.{
        .name = "nexus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nexus", .module = mod },
                // The project generator behind `nexus init`; shared with the
                // generated-project contract test so both emit identical files.
                .{ .name = "scaffold", .module = scaffold_mod },
            },
        }),
    });

    // Install the CLI into the prefix (default `zig-out/`) on the default step.
    b.installArtifact(exe);

    // `zig build run [-- args]` builds, installs, and runs the CLI.
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    // Run from the install dir, not straight out of the cache.
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // Each test binary covers exactly one module, so the library root and the
    // CLI's own root need separate test executables.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // `test` runs the in-process unit roots in parallel (independent run steps).
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // A fast, single-root step for the normal edit/test loop: just the library
    // unit tests (`src/root.zig`), which are the bulk of the suite. One compiler
    // process = bounded memory and a quick turnaround, so it is safe to run on
    // every change. The aggregate `test`/`test-all` steps compile several test
    // roots at once and are meant for pre-push / release verification.
    const test_lib_step = b.step("test-lib", "Run only the library unit tests (fast dev loop)");
    test_lib_step.dependOn(&run_mod_tests.step);

    // Integration tests exercise internal subsystems. Every source file may
    // only belong to one module, and `nexus` already pulls in this tree, so the
    // tests reach all internal types through the public `nexus` module.
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nexus", .module = mod },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);

    // Generated-project contract test: runs the `nexus init` generator into a
    // temp dir, compiles the emitted project with a child `zig build` against
    // this checkout, launches it on an ephemeral port, and performs one request.
    // Kept as its own step (not part of `test`) because it drives a full child
    // build and needs child-process + socket access. The child build needs the
    // absolute path of this very compiler, which is only known to the build
    // graph — pass it through a dedicated options module.
    const contract_options = b.addOptions();
    contract_options.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    const init_contract = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/init_contract.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nexus", .module = mod },
                .{ .name = "scaffold", .module = scaffold_mod },
                .{ .name = "contract_options", .module = contract_options.createModule() },
            },
        }),
    });
    const run_init_contract = b.addRunArtifact(init_contract);
    const init_contract_step = b.step("init-contract", "Generate, build, and smoke-test a `nexus init` project");
    init_contract_step.dependOn(&run_init_contract.step);

    // CLI contract test: runs the built `nexus` binary with a matrix of
    // arguments and asserts each command's exit status/output, pinning the
    // fail-closed CLI surface (NX-008). Kept out of `test` because it drives the
    // real executable as a subprocess. The binary path is injected through an
    // options module via `addOptionPath`, which also makes the test depend on
    // the compiled executable.
    const cli_options = b.addOptions();
    cli_options.addOptionPath("nexus_exe", exe.getEmittedBin());
    const cli_contract = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli_contract.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nexus", .module = mod },
                .{ .name = "cli_options", .module = cli_options.createModule() },
            },
        }),
    });
    const run_cli_contract = b.addRunArtifact(cli_contract);
    const cli_contract_step = b.step("cli-contract", "Run the CLI exit-status/output contract against the built nexus binary");
    cli_contract_step.dependOn(&run_cli_contract.step);

    // Group the socket/process integration contracts — the generated-project
    // child build + live request, and the real-binary CLI matrix — under one
    // name so the "integration" half of the suite has an explicit entry point
    // distinct from the pure in-process unit tests.
    const contracts_step = b.step("test-contracts", "Run the socket/process integration contracts (init + CLI)");
    contracts_step.dependOn(&run_init_contract.step);
    contracts_step.dependOn(&run_cli_contract.step);

    // The complete release suite as a single command: every in-process unit test
    // root plus both integration contracts. This compiles several test roots and
    // the executable, so it is heavier than `test-lib`/`test` and is intended for
    // pre-push / release verification rather than the inner dev loop.
    const test_all_step = b.step("test-all", "Run the complete release suite (unit tests + integration contracts)");
    test_all_step.dependOn(test_step);
    test_all_step.dependOn(contracts_step);

    // Compile every example against the public `nexus` module so the build
    // graph fails loudly when an example drifts from the API. `zig build
    // examples` builds them all; they are not installed by default.
    const examples_step = b.step("examples", "Build all examples");
    // database_demo is intentionally absent: the db drivers are gated out of the
    // public surface and do not compile against the pinned toolchain (NX-011).
    const example_names = [_][]const u8{
        "hello-world",
        "rest_api_todos",
        "static_server",
        "wasm_demo",
        "websocket_chat",
    };
    for (example_names) |name| {
        const example_exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "nexus", .module = mod },
                },
            }),
        });
        const install_example = b.addInstallArtifact(example_exe, .{});
        examples_step.dependOn(&install_example.step);
    }

    // Benchmarks compile against the public module too.
    const bench_step = b.step("bench", "Build benchmarks");
    const bench_exe = b.addExecutable(.{
        .name = "http_throughput",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/http_throughput.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nexus", .module = mod },
            },
        }),
    });
    const install_bench = b.addInstallArtifact(bench_exe, .{});
    bench_step.dependOn(&install_bench.step);

    // Release step: build ONLY the supported, shipped v0.1.2 artifact — the
    // `nexus` CLI — in ReleaseSafe. A network runtime keeps its safety checks in
    // production, so ReleaseSafe (not ReleaseFast) is the release mode. The
    // examples and benchmarks are deliberately outside the release surface and
    // are not produced here.
    const release_step = b.step("release", "Build the supported v0.1.2 release binary (nexus CLI, ReleaseSafe)");
    const release_exe = b.addExecutable(.{
        .name = "nexus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "nexus", .module = mod },
                .{ .name = "scaffold", .module = scaffold_mod },
            },
        }),
    });
    const install_release = b.addInstallArtifact(release_exe, .{});
    release_step.dependOn(&install_release.step);
}
