const std = @import("std");

pub const LogLevel = enum {
    debug,
    info,
    warn,
    @"error",

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .@"error" => "ERROR",
        };
    }

    pub fn color(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "\x1b[36m", // Cyan
            .info => "\x1b[32m", // Green
            .warn => "\x1b[33m", // Yellow
            .@"error" => "\x1b[31m", // Red
        };
    }
};

const reset_color = "\x1b[0m";

pub fn log(comptime fmt: []const u8, args: anytype) void {
    logWithLevel(.info, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    logWithLevel(.debug, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    logWithLevel(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    logWithLevel(.warn, fmt, args);
}

pub fn @"error"(comptime fmt: []const u8, args: anytype) void {
    logWithLevel(.@"error", fmt, args);
}

pub fn logWithLevel(level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    // Write log with color using std.debug.print (simplified - no timestamp for now)
    std.debug.print("{s}[{s}]{s} ", .{
        level.color(),
        level.toString(),
        reset_color,
    });

    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

/// Print formatted message to stdout
pub fn print(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// Print formatted message to stdout with newline
pub fn println(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

/// Print error message to stderr
pub fn printError(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}Error:{s} ", .{ "\x1b[31m", reset_color });
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

/// Clear console screen
pub fn clear() void {
    std.debug.print("\x1b[2J\x1b[H", .{});
}

test "console logging" {
    log("Test message: {s}", .{"hello"});
    debug("Debug message: {d}", .{42});
    info("Info message", .{});
    warn("Warning message", .{});
    @"error"("Error message", .{});
}
