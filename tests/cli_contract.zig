//! CLI contract test.
//!
//! Runs the built `nexus` binary with a matrix of arguments and asserts the
//! exit status (and, for the informational commands, the key output) of each.
//! This pins the fail-closed CLI surface established during stabilization —
//! `nexus test`/`deploy`, `run` with a missing argument or file, and unknown
//! commands must exit nonzero instead of faking success (NX-008) — so a future
//! change cannot silently turn a non-working command back into a green exit.
//!
//! The binary's path is injected by the build graph through
//! `cli_options.nexus_exe` (an `addOptionPath`), which also wires the build
//! dependency so the executable is compiled before this test runs. All CLI
//! output is written via `std.debug.print`, i.e. to stderr, so assertions look
//! there.

const std = @import("std");
const builtin = @import("builtin");
const nexus = @import("nexus");
const cli_options = @import("cli_options");

const nexus_exe = cli_options.nexus_exe;

// Spawn the built binary with `args`, returning the captured result. Caller
// frees `stdout`/`stderr`.
fn runCli(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, nexus_exe);
    try argv.appendSlice(allocator, args);
    return std.process.run(allocator, io, .{ .argv = argv.items });
}

// Assert the binary exited with a nonzero status for `args` (fail-closed).
fn expectFailsClosed(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    const result = try runCli(allocator, io, args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| try std.testing.expect(code != 0),
        else => return error.AbnormalTermination,
    }
}

test "help exits zero and prints usage" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const result = try runCli(allocator, io, &.{"--help"});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Usage: nexus <command>") != null);
}

test "version exits zero and prints the manifest version" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const result = try runCli(allocator, io, &.{"--version"});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // The version string derives from the manifest via the `nexus` module, so
    // this also proves the printed version matches the single source of truth.
    const needle = "Nexus Runtime v" ++ nexus.version;
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, needle) != null);
}

test "no arguments prints usage and exits zero" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const result = try runCli(allocator, io, &.{});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Usage: nexus <command>") != null);
}

test "an unknown command fails closed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try expectFailsClosed(allocator, io, &.{"definitely-not-a-command"});
}

test "the unimplemented test command fails closed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    // Historically printed a green success and exited 0 (NX-008); must be nonzero.
    try expectFailsClosed(allocator, io, &.{"test"});
}

test "the unimplemented deploy command fails closed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try expectFailsClosed(allocator, io, &.{"deploy"});
}

test "run without a file argument fails closed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try expectFailsClosed(allocator, io, &.{"run"});
}

test "run of a missing file fails closed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try expectFailsClosed(allocator, io, &.{ "run", "this-file-does-not-exist-12345.zig" });
}
