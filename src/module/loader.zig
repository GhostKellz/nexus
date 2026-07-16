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
    /// Open handle for `.dynamic` modules. Any function pointer stored in
    /// `exports` (or returned from a lookup) points into this loaded image and
    /// is valid only while the handle is open, so the handle must live for the
    /// whole module lifetime and is closed last in `deinit`.
    dyn_lib: ?std.DynLib = null,

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
        // Close after exports so no borrowed function pointer is used post-unmap.
        if (self.dyn_lib) |*lib| {
            lib.close();
            self.dyn_lib = null;
        }
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
            .search_paths = .empty,
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

    /// Resolve module specifier to absolute path. `io` is required because
    /// resolution probes the filesystem (`fileExists`) via `std.Io.Dir`.
    pub fn resolve(self: *ModuleResolver, io: std.Io, specifier: []const u8, parent: ?[]const u8) !ResolveResult {
        // 1. Built-in modules (nexus:*)
        if (std.mem.startsWith(u8, specifier, "nexus:")) {
            return self.resolveBuiltin(specifier);
        }

        // 2. Relative paths (./foo, ../bar)
        if (std.mem.startsWith(u8, specifier, "./") or
            std.mem.startsWith(u8, specifier, "../"))
        {
            return self.resolveRelative(io, specifier, parent);
        }

        // 3. Absolute paths
        if (std.fs.path.isAbsolute(specifier)) {
            return self.resolveAbsolute(io, specifier);
        }

        // 4. Package resolution (node_modules style)
        return self.resolvePackage(io, specifier, parent);
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

    fn resolveRelative(self: *ModuleResolver, io: std.Io, specifier: []const u8, parent: ?[]const u8) !ResolveResult {
        const parent_dir = if (parent) |p|
            std.fs.path.dirname(p) orelse "."
        else
            ".";

        const resolved = try std.fs.path.join(self.allocator, &.{ parent_dir, specifier });
        errdefer self.allocator.free(resolved);

        // Try exact path
        if (try self.fileExists(io, resolved)) {
            return ResolveResult{
                .path = resolved,
                .type = try self.detectType(resolved),
                .allocator = self.allocator,
            };
        }

        // Try with .zig extension
        const zig_path = try std.fmt.allocPrint(self.allocator, "{s}.zig", .{resolved});
        defer self.allocator.free(zig_path);

        if (try self.fileExists(io, zig_path)) {
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

        if (try self.fileExists(io, wasm_path)) {
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

    fn resolveAbsolute(self: *ModuleResolver, io: std.Io, specifier: []const u8) !ResolveResult {
        if (try self.fileExists(io, specifier)) {
            return ResolveResult{
                .path = try self.allocator.dupe(u8, specifier),
                .type = try self.detectType(specifier),
                .allocator = self.allocator,
            };
        }
        return error.ModuleNotFound;
    }

    fn resolvePackage(self: *ModuleResolver, io: std.Io, specifier: []const u8, parent: ?[]const u8) !ResolveResult {
        // Search node_modules-style directories
        var current_dir = if (parent) |p| std.fs.path.dirname(p) orelse "." else ".";

        while (true) {
            const node_modules = try std.fs.path.join(
                self.allocator,
                &.{ current_dir, "node_modules", specifier },
            );
            defer self.allocator.free(node_modules);

            if (try self.fileExists(io, node_modules)) {
                return ResolveResult{
                    .path = try self.allocator.dupe(u8, node_modules),
                    .type = try self.detectType(node_modules),
                    .allocator = self.allocator,
                };
            }

            // Try with extensions
            const zig_path = try std.fmt.allocPrint(self.allocator, "{s}.zig", .{node_modules});
            defer self.allocator.free(zig_path);

            if (try self.fileExists(io, zig_path)) {
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

    fn fileExists(self: *ModuleResolver, io: std.Io, path: []const u8) !bool {
        _ = self;
        std.Io.Dir.cwd().access(io, path, .{}) catch |err| {
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
        if (self.cache.fetchRemove(path)) |kv| return kv.value;
        return null;
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

    pub fn load(self: *ModuleLoader, io: std.Io, specifier: []const u8, parent: ?[]const u8) !*Module {
        // Resolve module path
        var resolved = try self.resolver.resolve(io, specifier, parent);
        defer resolved.deinit();

        // Check cache
        if (self.cache.get(resolved.path)) |cached| {
            return cached;
        }

        // Load module based on type
        const module = try self.allocator.create(Module);
        errdefer self.allocator.destroy(module);

        module.* = try Module.init(self.allocator, resolved.path, resolved.type);
        // If a loader below fails, release the module's owned resources (path,
        // exports map, dyn_lib) before freeing the struct itself.
        errdefer module.deinit();

        switch (resolved.type) {
            .native => try self.loadNative(module),
            .wasm => try self.loadWasm(io, module),
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

    fn loadWasm(self: *ModuleLoader, io: std.Io, module: *Module) !void {
        // Load WASM module from file
        const file_content = std.Io.Dir.cwd().readFileAlloc(
            io,
            module.path,
            self.allocator,
            std.Io.Limit.limited(10 * 1024 * 1024), // 10MB max
        ) catch |err| {
            std.debug.print("Failed to read WASM file {s}: {}\n", .{ module.path, err });
            return error.ModuleNotFound;
        };
        defer self.allocator.free(file_content);

        // Validate WASM magic number
        if (file_content.len < 8) {
            return error.InvalidModule;
        }
        const magic = file_content[0..4];
        const version = file_content[4..8];

        if (!std.mem.eql(u8, magic, "\x00asm")) {
            std.debug.print("Invalid WASM magic number in {s}\n", .{module.path});
            return error.InvalidModule;
        }

        // Check WASM version (1)
        if (!std.mem.eql(u8, version, "\x01\x00\x00\x00")) {
            std.debug.print("Unsupported WASM version in {s}\n", .{module.path});
            return error.InvalidModule;
        }

        // Module is valid WASM - in a full implementation this would:
        // 1. Parse the WASM sections
        // 2. Compile to native code or prepare for interpretation
        // 3. Register exports

        std.debug.print("✓ Loaded WASM module: {s} ({d} bytes)\n", .{ module.path, file_content.len });
    }

    fn loadDynamic(self: *ModuleLoader, module: *Module) !void {
        _ = self;
        // Dynamic library loading using std.DynLib. Hand the handle to the module
        // immediately so it stays mapped for the module's lifetime and is closed
        // exactly once in Module.deinit — the exports registered below borrow
        // function pointers from this image.
        module.dyn_lib = std.DynLib.open(module.path) catch |err| {
            std.debug.print("Failed to load dynamic library {s}: {}\n", .{ module.path, err });
            return error.ModuleNotFound;
        };
        const lib = &module.dyn_lib.?;

        // Look for standard export function
        const init_fn = lib.lookup(*const fn () void, "nexus_module_init");
        if (init_fn) |init_func| {
            // Call module initialization
            init_func();
            std.debug.print("✓ Loaded dynamic module: {s} (initialized)\n", .{module.path});
        } else {
            std.debug.print("✓ Loaded dynamic module: {s} (no init function)\n", .{module.path});
        }

        // Look for export registration function
        const register_fn = lib.lookup(*const fn (*std.StringHashMap(*anyopaque)) void, "nexus_register_exports");
        if (register_fn) |register| {
            register(&module.exports);
        }
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
