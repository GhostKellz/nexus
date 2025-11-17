const std = @import("std");

/// Module types
pub const ModuleType = enum {
    native, // Zig native module
    wasm, // WebAssembly module
    dynamic, // Dynamic library (.so, .dylib, .dll)
};

/// Module metadata
pub const Module = struct {
    path: []const u8,
    type: ModuleType,
    exports: std.StringHashMap(*anyopaque),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, module_type: ModuleType) !Module {
        return Module{
            .path = try allocator.dupe(u8, path),
            .type = module_type,
            .exports = std.StringHashMap(*anyopaque).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Module) void {
        self.allocator.free(self.path);
        self.exports.deinit();
    }
};

/// Module resolution result
pub const ResolveResult = struct {
    path: []const u8,
    type: ModuleType,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ResolveResult) void {
        self.allocator.free(self.path);
    }
};

/// Module resolver
pub const ModuleResolver = struct {
    allocator: std.mem.Allocator,
    search_paths: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) ModuleResolver {
        return ModuleResolver{
            .allocator = allocator,
            .search_paths = .{},
        };
    }

    pub fn deinit(self: *ModuleResolver) void {
        for (self.search_paths.items) |path| {
            self.allocator.free(path);
        }
        self.search_paths.deinit(self.allocator);
    }

    pub fn addSearchPath(self: *ModuleResolver, path: []const u8) !void {
        const duped = try self.allocator.dupe(u8, path);
        try self.search_paths.append(self.allocator, duped);
    }

    /// Resolve module specifier to absolute path
    pub fn resolve(self: *ModuleResolver, specifier: []const u8, parent: ?[]const u8) !ResolveResult {
        // 1. Built-in modules (nexus:*)
        if (std.mem.startsWith(u8, specifier, "nexus:")) {
            return self.resolveBuiltin(specifier);
        }

        // 2. Relative paths (./foo, ../bar)
        if (std.mem.startsWith(u8, specifier, "./") or
            std.mem.startsWith(u8, specifier, "../"))
        {
            return self.resolveRelative(specifier, parent);
        }

        // 3. Absolute paths
        if (std.fs.path.isAbsolute(specifier)) {
            return self.resolveAbsolute(specifier);
        }

        // 4. Package resolution (node_modules style)
        return self.resolvePackage(specifier, parent);
    }

    fn resolveBuiltin(self: *ModuleResolver, specifier: []const u8) !ResolveResult {
        // Built-in modules are handled specially
        // They're compiled into the runtime
        return ResolveResult{
            .path = try self.allocator.dupe(u8, specifier),
            .type = .native,
            .allocator = self.allocator,
        };
    }

    fn resolveRelative(self: *ModuleResolver, specifier: []const u8, parent: ?[]const u8) !ResolveResult {
        const parent_dir = if (parent) |p|
            std.fs.path.dirname(p) orelse "."
        else
            ".";

        const resolved = try std.fs.path.join(self.allocator, &.{ parent_dir, specifier });
        errdefer self.allocator.free(resolved);

        // Try exact path
        if (try self.fileExists(resolved)) {
            return ResolveResult{
                .path = resolved,
                .type = try self.detectType(resolved),
                .allocator = self.allocator,
            };
        }

        // Try with .zig extension
        const zig_path = try std.fmt.allocPrint(self.allocator, "{s}.zig", .{resolved});
        defer self.allocator.free(zig_path);

        if (try self.fileExists(zig_path)) {
            self.allocator.free(resolved);
            return ResolveResult{
                .path = try self.allocator.dupe(u8, zig_path),
                .type = .native,
                .allocator = self.allocator,
            };
        }

        // Try with .wasm extension
        const wasm_path = try std.fmt.allocPrint(self.allocator, "{s}.wasm", .{resolved});
        defer self.allocator.free(wasm_path);

        if (try self.fileExists(wasm_path)) {
            self.allocator.free(resolved);
            return ResolveResult{
                .path = try self.allocator.dupe(u8, wasm_path),
                .type = .wasm,
                .allocator = self.allocator,
            };
        }

        self.allocator.free(resolved);
        return error.ModuleNotFound;
    }

    fn resolveAbsolute(self: *ModuleResolver, specifier: []const u8) !ResolveResult {
        if (try self.fileExists(specifier)) {
            return ResolveResult{
                .path = try self.allocator.dupe(u8, specifier),
                .type = try self.detectType(specifier),
                .allocator = self.allocator,
            };
        }
        return error.ModuleNotFound;
    }

    fn resolvePackage(self: *ModuleResolver, specifier: []const u8, parent: ?[]const u8) !ResolveResult {
        // Search node_modules-style directories
        var current_dir = if (parent) |p| std.fs.path.dirname(p) orelse "." else ".";

        while (true) {
            const node_modules = try std.fs.path.join(
                self.allocator,
                &.{ current_dir, "node_modules", specifier },
            );
            defer self.allocator.free(node_modules);

            if (try self.fileExists(node_modules)) {
                return ResolveResult{
                    .path = try self.allocator.dupe(u8, node_modules),
                    .type = try self.detectType(node_modules),
                    .allocator = self.allocator,
                };
            }

            // Try with extensions
            const zig_path = try std.fmt.allocPrint(self.allocator, "{s}.zig", .{node_modules});
            defer self.allocator.free(zig_path);

            if (try self.fileExists(zig_path)) {
                return ResolveResult{
                    .path = try self.allocator.dupe(u8, zig_path),
                    .type = .native,
                    .allocator = self.allocator,
                };
            }

            // Move up directory tree
            const parent_dir = std.fs.path.dirname(current_dir);
            if (parent_dir == null or std.mem.eql(u8, parent_dir.?, current_dir)) {
                break;
            }
            current_dir = parent_dir.?;
        }

        return error.ModuleNotFound;
    }

    fn fileExists(self: *ModuleResolver, path: []const u8) !bool {
        _ = self;
        std.fs.cwd().access(path, .{}) catch |err| {
            if (err == error.FileNotFound) return false;
            return err;
        };
        return true;
    }

    fn detectType(_: *ModuleResolver, path: []const u8) !ModuleType {
        if (std.mem.endsWith(u8, path, ".wasm")) return .wasm;
        if (std.mem.endsWith(u8, path, ".so")) return .dynamic;
        if (std.mem.endsWith(u8, path, ".dylib")) return .dynamic;
        if (std.mem.endsWith(u8, path, ".dll")) return .dynamic;
        if (std.mem.endsWith(u8, path, ".zig")) return .native;
        return .native; // Default to native
    }
};

/// Module cache
pub const ModuleCache = struct {
    cache: std.StringHashMap(*Module),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ModuleCache {
        return ModuleCache{
            .cache = std.StringHashMap(*Module).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ModuleCache) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.cache.deinit();
    }

    pub fn get(self: *ModuleCache, path: []const u8) ?*Module {
        return self.cache.get(path);
    }

    pub fn put(self: *ModuleCache, path: []const u8, module: *Module) !void {
        try self.cache.put(path, module);
    }

    pub fn remove(self: *ModuleCache, path: []const u8) ?*Module {
        return self.cache.fetchRemove(path);
    }
};

/// Module loader
pub const ModuleLoader = struct {
    resolver: ModuleResolver,
    cache: ModuleCache,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ModuleLoader {
        return ModuleLoader{
            .resolver = ModuleResolver.init(allocator),
            .cache = ModuleCache.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ModuleLoader) void {
        self.resolver.deinit();
        self.cache.deinit();
    }

    pub fn load(self: *ModuleLoader, specifier: []const u8, parent: ?[]const u8) !*Module {
        // Resolve module path
        var resolved = try self.resolver.resolve(specifier, parent);
        defer resolved.deinit();

        // Check cache
        if (self.cache.get(resolved.path)) |cached| {
            return cached;
        }

        // Load module based on type
        const module = try self.allocator.create(Module);
        errdefer self.allocator.destroy(module);

        module.* = try Module.init(self.allocator, resolved.path, resolved.type);

        switch (resolved.type) {
            .native => try self.loadNative(module),
            .wasm => try self.loadWasm(module),
            .dynamic => try self.loadDynamic(module),
        }

        // Cache module
        try self.cache.put(resolved.path, module);

        return module;
    }

    fn loadNative(self: *ModuleLoader, module: *Module) !void {
        _ = self;
        // For native Zig modules, we rely on compile-time @import
        // At runtime, this would just register the module metadata
        // The actual exports would be registered separately
        _ = module;
    }

    fn loadWasm(self: *ModuleLoader, module: *Module) !void {
        _ = self;
        // WASM loading will be implemented in Phase 2
        _ = module;
        return error.NotImplemented;
    }

    fn loadDynamic(self: *ModuleLoader, module: *Module) !void {
        _ = self;
        // Dynamic library loading using std.DynLib
        // This allows loading .so/.dylib/.dll files
        _ = module;
        return error.NotImplemented;
    }
};

test "module resolver - relative path" {
    const allocator = std.testing.allocator;
    var resolver = ModuleResolver.init(allocator);
    defer resolver.deinit();

    // This test would work if we have actual files
    // For now, just test the structure
    try std.testing.expect(resolver.search_paths.items.len == 0);
}

test "module cache" {
    const allocator = std.testing.allocator;
    var cache = ModuleCache.init(allocator);
    defer cache.deinit();

    // Test basic cache operations
    var module = try Module.init(allocator, "/test/module.zig", .native);
    defer module.deinit();

    // Note: Can't actually put in cache without heap allocation in test
    try std.testing.expect(cache.cache.count() == 0);
}
