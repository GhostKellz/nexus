const std = @import("std");

/// ZIM package manager integration for Nexus
/// Provides package installation, dependency resolution, and version management
pub const PackageInfo = struct {
    name: []const u8,
    version: []const u8,
    description: ?[]const u8 = null,
    author: ?[]const u8 = null,
    license: ?[]const u8 = null,
    dependencies: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, version: []const u8) PackageInfo {
        return PackageInfo{
            .name = name,
            .version = version,
            .dependencies = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PackageInfo) void {
        var it = self.dependencies.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.dependencies.deinit();
    }

    pub fn addDependency(self: *PackageInfo, name: []const u8, version: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const version_copy = try self.allocator.dupe(u8, version);
        errdefer self.allocator.free(version_copy);

        try self.dependencies.put(name_copy, version_copy);
    }
};

pub const ZimClient = struct {
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    registry_url: []const u8,

    pub fn init(allocator: std.mem.Allocator) !ZimClient {
        // Get home directory for cache. std.posix.getenv was removed; read the
        // environment through the global IO provider instead.
        const home = std.Io.Threaded.global_single_threaded.environString("HOME") orelse
            return error.HomeNotFound;
        const cache_dir = try std.fmt.allocPrint(allocator, "{s}/.zim/cache", .{home});
        errdefer allocator.free(cache_dir);

        // Create cache directory if it doesn't exist. std.fs.cwd() was removed;
        // directory creation now goes through the IO-provided Dir API, and
        // createDirPath already treats an existing path as success.
        const io = std.Io.Threaded.global_single_threaded.io();
        try std.Io.Dir.cwd().createDirPath(io, cache_dir);

        return ZimClient{
            .allocator = allocator,
            .cache_dir = cache_dir,
            .registry_url = "https://packages.ziglang.org",
        };
    }

    pub fn deinit(self: *ZimClient) void {
        self.allocator.free(self.cache_dir);
    }

    /// Install a package from ZIM registry.
    ///
    /// Not implemented in v0.1.2. The previous body fabricated success: it never
    /// downloaded anything, created an empty directory from the caller-supplied
    /// package name/version (a path-traversal sink), and printed "✓ Installed".
    /// There was no registry fetch, no content-hash verification, and no
    /// signature check, so any caller trusting a "successful" install would be
    /// trusting an empty, unverified directory. Fail closed until a real
    /// download-and-verify pipeline lands in Phase 6.
    pub fn install(self: *ZimClient, package_name: []const u8, version: []const u8) !void {
        _ = self;
        _ = package_name;
        _ = version;
        return error.PackageOperationUnavailable;
    }

    /// Resolve dependencies for a package.
    ///
    /// Not implemented in v0.1.2. Resolution drove `install`, which fabricated
    /// success; reporting "✓ All dependencies resolved" over unverified,
    /// never-downloaded packages is worse than an honest failure. Fail closed
    /// until verified install lands in Phase 6.
    pub fn resolveDependencies(self: *ZimClient, package: *const PackageInfo) !void {
        _ = self;
        _ = package;
        return error.PackageOperationUnavailable;
    }

    /// Reject any package-identity component (name or version) that is not a
    /// single safe path segment. `getPackagePath` joins these strings directly
    /// into a filesystem path and `remove` runs `deleteTree` on the result, so a
    /// component of `..`, `a/b`, or `/etc` would escape the cache directory.
    /// This release targets Linux, but `\` and NUL are rejected as well so the
    /// guard stays correct if a caller forwards Windows-shaped input.
    fn validatePathComponent(component: []const u8) error{UnsafePackageComponent}!void {
        if (component.len == 0) return error.UnsafePackageComponent;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, ".."))
            return error.UnsafePackageComponent;
        for (component) |c| {
            if (c == '/' or c == '\\' or c == 0) return error.UnsafePackageComponent;
        }
    }

    /// Get package path in cache.
    ///
    /// Both identity components are validated as single safe path segments
    /// before the path is built; see `validatePathComponent`.
    pub fn getPackagePath(self: *ZimClient, package_name: []const u8, version: []const u8) ![]const u8 {
        try validatePathComponent(package_name);
        try validatePathComponent(version);
        return try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}",
            .{ self.cache_dir, package_name, version },
        );
    }

    /// List installed packages.
    ///
    /// Not implemented in v0.1.2. The local cache is only ever populated by
    /// `install`, which fails closed, so there is never anything to list. The
    /// previous body also used the removed blocking `std.fs.cwd()` API and never
    /// compiled once analyzed. Fail closed until a real install pipeline lands
    /// in Phase 6.
    pub fn listInstalled(self: *ZimClient) !std.ArrayList([]const u8) {
        _ = self;
        return error.PackageOperationUnavailable;
    }

    /// Remove a package from the local cache.
    ///
    /// Not implemented in v0.1.2. The cache is only populated by `install`,
    /// which fails closed, so there is nothing to remove. The previous body also
    /// used the removed blocking `std.fs.cwd()` API and ran `deleteTree` on a
    /// path built from caller-supplied strings. Fail closed until a real install
    /// pipeline lands in Phase 6; the path primitive `getPackagePath` still
    /// validates its components for any future caller.
    pub fn remove(self: *ZimClient, package_name: []const u8, version: []const u8) !void {
        _ = self;
        _ = package_name;
        _ = version;
        return error.PackageOperationUnavailable;
    }

    /// Update package index from registry.
    ///
    /// Not implemented in v0.1.2. The previous body fetched nothing yet printed
    /// "✓ Package index updated", so any later lookup would consult a stale or
    /// absent index while believing it was current. Fail closed until a real
    /// registry sync lands in Phase 6.
    pub fn updateIndex(self: *ZimClient) !void {
        _ = self;
        return error.PackageOperationUnavailable;
    }

    /// Search for packages.
    ///
    /// Not implemented in v0.1.2. The previous body returned hardcoded results
    /// ("http-client"/"http-server") for any query containing "http" regardless
    /// of what is actually published, which is misleading rather than useful.
    /// Fail closed until index-backed search lands in Phase 6.
    pub fn search(self: *ZimClient, query: []const u8) !std.ArrayList([]const u8) {
        _ = self;
        _ = query;
        return error.PackageOperationUnavailable;
    }
};

/// Nexus package manifest (nexus.json)
pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    description: ?[]const u8 = null,
    author: ?[]const u8 = null,
    license: ?[]const u8 = null,
    main: []const u8 = "src/main.zig",
    dependencies: std.StringHashMap([]const u8),
    dev_dependencies: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, version: []const u8) Manifest {
        return Manifest{
            .name = name,
            .version = version,
            .dependencies = std.StringHashMap([]const u8).init(allocator),
            .dev_dependencies = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Manifest) void {
        var it = self.dependencies.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.dependencies.deinit();

        var dev_it = self.dev_dependencies.iterator();
        while (dev_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.dev_dependencies.deinit();
    }

    /// JSON structure for nexus.json manifest parsing
    const ManifestJson = struct {
        name: []const u8,
        version: []const u8,
        description: ?[]const u8 = null,
        author: ?[]const u8 = null,
        license: ?[]const u8 = null,
        main: ?[]const u8 = null,
        dependencies: ?std.json.ObjectMap = null,
        devDependencies: ?std.json.ObjectMap = null,
    };

    /// Load manifest from nexus.json
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Manifest {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
        defer allocator.free(content);

        // Parse JSON using std.json
        const parsed = std.json.parseFromSlice(ManifestJson, allocator, content, .{
            .ignore_unknown_fields = true,
        }) catch return error.InvalidManifest;
        defer parsed.deinit();

        const v = parsed.value;

        // Create manifest with parsed values
        var manifest = Manifest{
            .name = try allocator.dupe(u8, v.name),
            .version = try allocator.dupe(u8, v.version),
            .description = if (v.description) |d| try allocator.dupe(u8, d) else null,
            .author = if (v.author) |a| try allocator.dupe(u8, a) else null,
            .license = if (v.license) |l| try allocator.dupe(u8, l) else null,
            .main = if (v.main) |m| try allocator.dupe(u8, m) else "src/main.zig",
            .dependencies = std.StringHashMap([]const u8).init(allocator),
            .dev_dependencies = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };

        // Parse dependencies
        if (v.dependencies) |deps| {
            var it = deps.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                const value = switch (entry.value_ptr.*) {
                    .string => |s| try allocator.dupe(u8, s),
                    else => continue,
                };
                try manifest.dependencies.put(key, value);
            }
        }

        // Parse devDependencies
        if (v.devDependencies) |deps| {
            var it = deps.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                const value = switch (entry.value_ptr.*) {
                    .string => |s| try allocator.dupe(u8, s),
                    else => continue,
                };
                try manifest.dev_dependencies.put(key, value);
            }
        }

        std.debug.print("✓ Loaded manifest from {s}\n", .{path});

        return manifest;
    }

    /// Save manifest to nexus.json
    pub fn save(self: *Manifest, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        // Write JSON
        try file.writeAll("{\n");
        try file.writer().print("  \"name\": \"{s}\",\n", .{self.name});
        try file.writer().print("  \"version\": \"{s}\",\n", .{self.version});
        try file.writer().print("  \"main\": \"{s}\",\n", .{self.main});

        if (self.description) |desc| {
            try file.writer().print("  \"description\": \"{s}\",\n", .{desc});
        }

        try file.writeAll("  \"dependencies\": {\n");
        var it = self.dependencies.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try file.writeAll(",\n");
            try file.writer().print("    \"{s}\": \"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
            first = false;
        }
        try file.writeAll("\n  }\n");
        try file.writeAll("}\n");

        std.debug.print("✓ Saved manifest to {s}\n", .{path});
    }

    pub fn addDependency(self: *Manifest, name: []const u8, version: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const version_copy = try self.allocator.dupe(u8, version);
        errdefer self.allocator.free(version_copy);

        try self.dependencies.put(name_copy, version_copy);
    }
};

test "zim client init" {
    const allocator = std.testing.allocator;

    var client = try ZimClient.init(allocator);
    defer client.deinit();

    try std.testing.expect(client.cache_dir.len > 0);
}

test "package info" {
    const allocator = std.testing.allocator;

    var pkg = PackageInfo.init(allocator, "test-pkg", "1.0.0");
    defer pkg.deinit();

    try pkg.addDependency("dep1", "^2.0.0");
    try pkg.addDependency("dep2", "~1.5.0");

    try std.testing.expectEqual(@as(usize, 2), pkg.dependencies.count());
}

test "zim install fails closed instead of fabricating success" {
    const allocator = std.testing.allocator;

    var client = try ZimClient.init(allocator);
    defer client.deinit();

    // Install must not report success without a verified download. A
    // traversal-shaped name/version must not be silently turned into an
    // on-disk directory either; the fail-closed return prevents both.
    try std.testing.expectError(error.PackageOperationUnavailable, client.install("http-client", "1.0.0"));
    try std.testing.expectError(error.PackageOperationUnavailable, client.install("../../etc", "1.0.0"));
}

test "zim getPackagePath rejects traversal-shaped components before building a path" {
    const allocator = std.testing.allocator;

    var client = try ZimClient.init(allocator);
    defer client.deinit();

    // A well-formed name/version resolves to a path under the cache directory.
    const ok = try client.getPackagePath("http-client", "1.0.0");
    defer allocator.free(ok);
    try std.testing.expect(std.mem.endsWith(u8, ok, "/http-client/1.0.0"));

    // Traversal-shaped identity components are refused before any path is
    // constructed, in either the name or the version position.
    try std.testing.expectError(error.UnsafePackageComponent, client.getPackagePath("..", "1.0.0"));
    try std.testing.expectError(error.UnsafePackageComponent, client.getPackagePath("a/b", "1.0.0"));
    try std.testing.expectError(error.UnsafePackageComponent, client.getPackagePath("/etc", "1.0.0"));
    try std.testing.expectError(error.UnsafePackageComponent, client.getPackagePath("pkg", ".."));
    try std.testing.expectError(error.UnsafePackageComponent, client.getPackagePath("", "1.0.0"));
}

test "zim local cache operations fail closed instead of touching the filesystem" {
    const allocator = std.testing.allocator;

    var client = try ZimClient.init(allocator);
    defer client.deinit();

    // The cache can only be populated by `install`, which is unavailable, so
    // `remove` and `listInstalled` must fail closed rather than run filesystem
    // side effects (the previous bodies used a removed blocking API). Even a
    // traversal-shaped name never reaches `deleteTree`.
    try std.testing.expectError(error.PackageOperationUnavailable, client.remove("http-client", "1.0.0"));
    try std.testing.expectError(error.PackageOperationUnavailable, client.remove("../../etc", "1.0.0"));
    try std.testing.expectError(error.PackageOperationUnavailable, client.listInstalled());
}

test "zim search fails closed instead of returning fabricated results" {
    const allocator = std.testing.allocator;

    var client = try ZimClient.init(allocator);
    defer client.deinit();

    try std.testing.expectError(error.PackageOperationUnavailable, client.search("http"));
    try std.testing.expectError(error.PackageOperationUnavailable, client.search("anything"));
}

test "zim updateIndex fails closed instead of claiming a fresh index" {
    const allocator = std.testing.allocator;

    var client = try ZimClient.init(allocator);
    defer client.deinit();

    try std.testing.expectError(error.PackageOperationUnavailable, client.updateIndex());
}

test "zim resolveDependencies fails closed instead of trusting empty installs" {
    const allocator = std.testing.allocator;

    var client = try ZimClient.init(allocator);
    defer client.deinit();

    var pkg = PackageInfo.init(allocator, "app", "1.0.0");
    defer pkg.deinit();
    try pkg.addDependency("http-client", "1.0.0");

    try std.testing.expectError(error.PackageOperationUnavailable, client.resolveDependencies(&pkg));
}
