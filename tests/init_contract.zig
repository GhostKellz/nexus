//! Generated-project contract test.
//!
//! Proves that `nexus init` output is real: the shared `scaffold` generator is
//! run into a Zig-managed temporary directory, the emitted project is compiled
//! with a child `zig build` against this very checkout of `nexus`, the built
//! server is launched on an ephemeral port, and a single HTTP request is served
//! with the expected body. Everything is torn down through `tmpDir.cleanup`.
//!
//! This is the regression guard for the generator: if `scaffold` ever emits a
//! stale API (e.g. the removed `server.get`), a broken `build.zig`/`build.zig.zon`,
//! or an entry point that does not run, this test fails at the child build or the
//! live request instead of shipping a project that does not work.

const std = @import("std");
const builtin = @import("builtin");
const nexus = @import("nexus");
const scaffold = @import("scaffold");
const contract_options = @import("contract_options");

const Io = std.Io;

test "nexus init output builds and serves a request" {
    // The runtime is Linux-only for this release, and the test spawns child
    // processes and binds sockets; keep it on the supported platform.
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const project = "contract_app";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Absolute path of the temp dir and of this checkout (the `nexus` package),
    // so the generated `build.zig.zon` can point its `.nexus` dependency at the
    // repo with a build-root-relative path (absolute paths are rejected there).
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_abs = tmp_buf[0..try tmp.dir.realPath(io, &tmp_buf)];
    const gen_abs = try std.fs.path.join(allocator, &.{ tmp_abs, project });
    defer allocator.free(gen_abs);

    // `Io.Dir.cwd()` carries the `AT_FDCWD` sentinel handle, which `realPath`
    // cannot resolve through `/proc/self/fd`; open the working directory as a
    // real handle (the child `zig build` runs from the repo root) instead.
    var repo_dir = try Io.Dir.cwd().openDir(io, ".", .{});
    defer repo_dir.close(io);
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo_abs = repo_buf[0..try repo_dir.realPath(io, &repo_buf)];

    // `from`/`to` are absolute, so the `cwd`/`environ_map` arguments (only used
    // to resolve relative inputs) are irrelevant on this platform.
    const nexus_rel = try std.fs.path.relative(allocator, "", null, gen_abs, repo_abs);
    defer allocator.free(nexus_rel);

    // 1. Generate the project via the exact generator the CLI uses.
    try scaffold.create(tmp.dir, allocator, io, project, nexus_rel);

    // 2. Compile it with a child `zig build` against this checkout.
    var build_child = try std.process.spawn(io, .{
        .argv = &.{ contract_options.zig_exe, "build" },
        .cwd = .{ .path = gen_abs },
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const build_term = try build_child.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, build_term);

    // The build must have produced the runnable artifact.
    _ = tmp.dir.statFile(io, project ++ "/zig-out/bin/" ++ project, .{}) catch
        return error.GeneratedArtifactMissing;

    // 3. Reserve an ephemeral port, then hand it to the built server as argv[1].
    const port = blk: {
        var probe = try nexus.net.TcpServer.init(allocator, "127.0.0.1", 0);
        defer probe.deinit();
        break :blk probe.boundPort();
    };
    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_str);

    const bin_abs = try std.fs.path.join(allocator, &.{ gen_abs, "zig-out", "bin", project });
    defer allocator.free(bin_abs);

    var app = try std.process.spawn(io, .{
        .argv = &.{ bin_abs, port_str },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer app.kill(io);

    // 4. Poll until the server is accepting, then perform one request.
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api/hello", .{port});
    defer allocator.free(url);

    // Park between poll attempts through the pinned `std.Io` model rather than a
    // raw thread sleep, matching the runtime's own timeout usage.
    const poll_delay = Io.Timeout{
        .duration = .{ .raw = Io.Duration.fromMilliseconds(100), .clock = .awake },
    };

    var body: ?[]const u8 = null;
    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        poll_delay.sleep(io) catch {};
        var client = nexus.http.Client.init(allocator) catch continue;
        const got = client.get(url) catch {
            client.deinit();
            continue;
        };
        client.deinit();
        body = got;
        break;
    }

    const response = body orelse return error.ServerNeverResponded;
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "Hello from Nexus!") != null);
}
