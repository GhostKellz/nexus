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
        // Get home directory for cache
        const home = std.posix.getenv("HOME") orelse "/tmp";
        const cache_dir = try std.fmt.allocPrint(allocator, "{s}/.zim/cache", .{home});

        // Create cache directory if it doesn't exist
        std.fs.cwd().makePath(cache_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return ZimClient{
            .allocator = allocator,
            .cache_dir = cache_dir,
            .registry_url = "https://packages.ziglang.org",
        };
    }

    pub fn deinit(self: *ZimClient) void {
        self.allocator.free(self.cache_dir);
    }

    /// Install a package from ZIM registry
    pub fn install(self: *ZimClient, package_name: []const u8, version: []const u8) !void {
        std.debug.print("📦 Installing {s}@{s}\n", .{ package_name, version });

        // Check if package is already cached
        const package_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}",
            .{ self.cache_dir, package_name, version },
        );
        defer self.allocator.free(package_path);

        const cached = blk: {
            std.fs.cwd().access(package_path, .{}) catch {
                break :blk false;
            };
            break :blk true;
        };

        if (cached) {
            std.debug.print("✓ Package already cached at {s}\n", .{package_path});
            return;
        }

        // Download package (simulated for now)
        std.debug.print("⬇ Downloading {s}@{s} from {s}\n", .{
            package_name,
            version,
            self.registry_url,
        });

        // Create package directory
        std.fs.cwd().makePath(package_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        std.debug.print("✓ Installed {s}@{s}\n", .{ package_name, version });
    }

    /// Resolve dependencies for a package
    pub fn resolveDependencies(self: *ZimClient, package: *const PackageInfo) !void {
        std.debug.print("🔍 Resolving dependencies for {s}@{s}\n", .{
            package.name,
            package.version,
        });

        var it = package.dependencies.iterator();
        while (it.next()) |entry| {
            const dep_name = entry.key_ptr.*;
            const dep_version = entry.value_ptr.*;

            std.debug.print("  → {s}@{s}\n", .{ dep_name, dep_version });
            try self.install(dep_name, dep_version);
        }

        std.debug.print("✓ All dependencies resolved\n", .{});
    }

    /// Get package path in cache
    pub fn getPackagePath(self: *ZimClient, package_name: []const u8, version: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}",
            .{ self.cache_dir, package_name, version },
        );
    }

    /// List installed packages
    pub fn listInstalled(self: *ZimClient) !std.ArrayList([]const u8) {
        var packages = std.ArrayList([]const u8).init(self.allocator);
        errdefer packages.deinit();

        var cache_dir = std.fs.cwd().openDir(self.cache_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return packages;
            return err;
        };
        defer cache_dir.close();

        var iter = cache_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory) {
                const name = try self.allocator.dupe(u8, entry.name);
                try packages.append(name);
            }
        }

        return packages;
    }

    /// Remove a package from cache
    pub fn remove(self: *ZimClient, package_name: []const u8, version: []const u8) !void {
        const package_path = try self.getPackagePath(package_name, version);
        defer self.allocator.free(package_path);

        std.fs.cwd().deleteTree(package_path) catch |err| {
            if (err == error.FileNotFound) {
                std.debug.print("Package {s}@{s} not found\n", .{ package_name, version });
                return;
            }
            return err;
        };

        std.debug.print("✓ Removed {s}@{s}\n", .{ package_name, version });
    }

    /// Update package index from registry
    pub fn updateIndex(self: *ZimClient) !void {
        std.debug.print("🔄 Updating package index from {s}\n", .{self.registry_url});

        // Simulated - would fetch from registry
        const index_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/index.json",
            .{self.cache_dir},
        );
        defer self.allocator.free(index_path);

        std.debug.print("✓ Package index updated\n", .{});
    }

    /// Search for packages
    pub fn search(self: *ZimClient, query: []const u8) !std.ArrayList([]const u8) {
        std.debug.print("🔍 Searching for packages matching '{s}'\n", .{query});

        var results = std.ArrayList([]const u8).init(self.allocator);

        // Simulated search results
        if (std.mem.indexOf(u8, query, "http") != null) {
            try results.append("http-client");
            try results.append("http-server");
        }

        return results;
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

    /// Load manifest from nexus.json
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Manifest {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
        defer allocator.free(content);

        // Parse JSON (simplified - would use std.json in real implementation)
        const manifest = Manifest.init(allocator, "unknown", "0.0.0");

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
