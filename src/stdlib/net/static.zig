const std = @import("std");
const builtin = @import("builtin");
const http = @import("http.zig");
const fs = @import("../fs/file.zig");
const tcp = @import("tcp.zig");

/// HTTP date parsing for conditional requests
/// Supports RFC 1123, RFC 850, and ANSI C asctime() formats
pub const HttpDate = struct {
    /// Month name to number mapping
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };

    /// Parse month name to 1-indexed month number
    fn parseMonth(name: []const u8) ?u4 {
        for (months, 0..) |m, i| {
            if (std.mem.eql(u8, name, m)) {
                return @intCast(i + 1);
            }
        }
        return null;
    }

    /// Parse HTTP date string to Unix timestamp (seconds since epoch)
    /// Supports:
    /// - RFC 1123: "Sun, 06 Nov 1994 08:49:37 GMT"
    /// - RFC 850:  "Sunday, 06-Nov-94 08:49:37 GMT"
    /// - asctime:  "Sun Nov  6 08:49:37 1994"
    pub fn parse(date_str: []const u8) ?i64 {
        // Try RFC 1123 first (most common): "Sun, 06 Nov 1994 08:49:37 GMT"
        if (parseRfc1123(date_str)) |ts| return ts;

        // Try RFC 850: "Sunday, 06-Nov-94 08:49:37 GMT"
        if (parseRfc850(date_str)) |ts| return ts;

        // Try asctime: "Sun Nov  6 08:49:37 1994"
        if (parseAsctime(date_str)) |ts| return ts;

        return null;
    }

    /// Parse RFC 1123 date: "Sun, 06 Nov 1994 08:49:37 GMT"
    fn parseRfc1123(date_str: []const u8) ?i64 {
        // Skip day name and comma
        const after_comma = std.mem.indexOf(u8, date_str, ", ") orelse return null;
        const rest = date_str[after_comma + 2 ..];

        // Parse: "06 Nov 1994 08:49:37 GMT"
        if (rest.len < 20) return null;

        const day = std.fmt.parseInt(u5, rest[0..2], 10) catch return null;
        const month = parseMonth(rest[3..6]) orelse return null;
        const year = std.fmt.parseInt(u16, rest[7..11], 10) catch return null;
        const hour = std.fmt.parseInt(u5, rest[12..14], 10) catch return null;
        const minute = std.fmt.parseInt(u6, rest[15..17], 10) catch return null;
        const second = std.fmt.parseInt(u6, rest[18..20], 10) catch return null;

        return toUnixTimestamp(year, month, day, hour, minute, second);
    }

    /// Parse RFC 850 date: "Sunday, 06-Nov-94 08:49:37 GMT"
    fn parseRfc850(date_str: []const u8) ?i64 {
        // Skip day name and comma
        const after_comma = std.mem.indexOf(u8, date_str, ", ") orelse return null;
        const rest = date_str[after_comma + 2 ..];

        // Parse: "06-Nov-94 08:49:37 GMT"
        if (rest.len < 18) return null;

        const day = std.fmt.parseInt(u5, rest[0..2], 10) catch return null;
        const month = parseMonth(rest[3..6]) orelse return null;
        var year = std.fmt.parseInt(u16, rest[7..9], 10) catch return null;

        // Convert 2-digit year: 00-69 = 2000-2069, 70-99 = 1970-1999
        if (year < 70) {
            year += 2000;
        } else {
            year += 1900;
        }

        const hour = std.fmt.parseInt(u5, rest[10..12], 10) catch return null;
        const minute = std.fmt.parseInt(u6, rest[13..15], 10) catch return null;
        const second = std.fmt.parseInt(u6, rest[16..18], 10) catch return null;

        return toUnixTimestamp(year, month, day, hour, minute, second);
    }

    /// Parse asctime date: "Sun Nov  6 08:49:37 1994"
    fn parseAsctime(date_str: []const u8) ?i64 {
        if (date_str.len < 24) return null;

        const month = parseMonth(date_str[4..7]) orelse return null;

        // Day can be space-padded: " 6" or "06"
        const day_str = std.mem.trim(u8, date_str[8..10], " ");
        const day = std.fmt.parseInt(u5, day_str, 10) catch return null;

        const hour = std.fmt.parseInt(u5, date_str[11..13], 10) catch return null;
        const minute = std.fmt.parseInt(u6, date_str[14..16], 10) catch return null;
        const second = std.fmt.parseInt(u6, date_str[17..19], 10) catch return null;
        const year = std.fmt.parseInt(u16, date_str[20..24], 10) catch return null;

        return toUnixTimestamp(year, month, day, hour, minute, second);
    }

    /// Convert date components to Unix timestamp
    fn toUnixTimestamp(year: u16, month: u4, day: u5, hour: u5, minute: u6, second: u6) ?i64 {
        // Use Zig's epoch calculation
        const epoch_day = epochDay(year, month, day) catch return null;
        const day_seconds: i64 = @as(i64, epoch_day) * 86400;
        const time_seconds: i64 = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
        return day_seconds + time_seconds;
    }

    /// Calculate days since Unix epoch (1970-01-01)
    fn epochDay(year: u16, month: u4, day: u5) !i32 {
        var y: i32 = @intCast(year);
        var m: i32 = @intCast(month);
        const d: i32 = @intCast(day);

        // Adjust for months (March = 1)
        if (m <= 2) {
            y -= 1;
            m += 12;
        }
        m -= 3;

        // Calculate days
        const era: i32 = @divFloor(y, 400);
        const yoe: i32 = @mod(y, 400);
        const doy: i32 = @divFloor(153 * m + 2, 5) + d - 1;
        const doe: i32 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;

        // Days since epoch (1970-01-01 is day 0)
        return era * 146097 + doe - 719468;
    }

    /// Format a Unix timestamp as RFC 1123 date
    pub fn format(timestamp: i64, buf: []u8) ![]const u8 {
        const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

        // Calculate date components from timestamp
        const days_since_epoch: i64 = @divFloor(timestamp, 86400);
        const time_of_day: u32 = @intCast(@mod(timestamp, 86400));

        const hour: u8 = @intCast(time_of_day / 3600);
        const minute: u8 = @intCast((time_of_day % 3600) / 60);
        const second: u8 = @intCast(time_of_day % 60);

        // Day of week (1970-01-01 was Thursday = 4)
        const dow: usize = @intCast(@mod(days_since_epoch + 4, 7));

        // Calculate year, month, day from days since epoch
        const z: i64 = days_since_epoch + 719468;
        const era: i64 = @divFloor(z, 146097);
        const doe: i64 = @mod(z, 146097);
        const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
        const y: i64 = yoe + era * 400;
        const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp: i64 = @divFloor(5 * doy + 2, 153);
        const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
        const m_raw: i64 = if (mp < 10) mp + 3 else mp - 9;
        const m: usize = @intCast(m_raw);
        const year: u16 = @intCast(if (m <= 2) y + 1 else y);

        return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
            day_names[dow],
            d,
            months[m - 1],
            year,
            hour,
            minute,
            second,
        });
    }
};

pub const StaticFileOptions = struct {
    index: ?[]const u8 = "index.html",
    dot_files: bool = false, // Allow serving hidden files
    cache_control: ?[]const u8 = "public, max-age=3600",
    enable_etag: bool = true,
    enable_range: bool = true,
};

/// Calculate ETag from file stats
fn calculateETag(file_stat: std.Io.File.Stat, allocator: std.mem.Allocator) ![]u8 {
    // Use size and mtime for ETag (weak validator)
    return try std.fmt.allocPrint(
        allocator,
        "W/\"{d}-{d}\"",
        .{ file_stat.size, file_stat.mtime.nanoseconds },
    );
}

/// Check if client's cached version is still valid
fn checkNotModified(req: *http.Request, etag: []const u8, last_modified: i64) bool {
    // Check If-None-Match (ETag) - takes precedence
    if (req.getHeader("if-none-match")) |client_etag| {
        if (std.mem.eql(u8, client_etag, etag)) {
            return true;
        }
    }

    // Check If-Modified-Since
    if (req.getHeader("if-modified-since")) |client_date| {
        if (HttpDate.parse(client_date)) |client_timestamp| {
            // Convert last_modified from nanoseconds to seconds
            const server_timestamp = @divFloor(last_modified, std.time.ns_per_s);
            // Not modified if client's date is >= server's last modified time
            if (client_timestamp >= server_timestamp) {
                return true;
            }
        }
    }

    return false;
}

/// A resolved, satisfiable byte range with absolute, inclusive bounds.
const RangeSpec = struct {
    start: u64,
    end: u64, // inclusive
};

/// Outcome of interpreting a `Range` header against a known file size.
const RangeResult = union(enum) {
    /// No range semantics this server acts on (missing/unsupported unit,
    /// multiple ranges, or syntactically invalid). Serving the full 200 entity
    /// is always a safe response, so these are ignored rather than rejected.
    none,
    /// A satisfiable single byte range → 206 Partial Content.
    satisfiable: RangeSpec,
    /// A syntactically valid byte range that cannot be satisfied against this
    /// file → 416 with `Content-Range: bytes */<size>`.
    unsatisfiable,
};

/// Interpret a single `Range` header (RFC 9110 §14). Only the `bytes` unit and a
/// single range are handled; `bytes=A-B`, `bytes=A-` (to EOF), and `bytes=-N`
/// (final N bytes) are all supported. An out-of-range or empty-selection range
/// is reported `unsatisfiable` (→ 416) rather than silently served as a full
/// 200, which would mislead a client that asked to resume a download.
fn parseRange(range_header: []const u8, file_size: u64) RangeResult {
    if (!std.mem.startsWith(u8, range_header, "bytes=")) return .none;
    const spec = range_header["bytes=".len..];

    // Multi-range ("a-b,c-d") is valid HTTP but needs multipart/byteranges
    // framing this server does not emit; ignore it and serve the full entity.
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return .none;

    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return .none;
    const start_str = spec[0..dash];
    const end_str = spec[dash + 1 ..];

    if (start_str.len == 0) {
        // Suffix range: the last N bytes. "-0" selects nothing, and any suffix
        // of an empty file is unsatisfiable.
        const n = std.fmt.parseInt(u64, end_str, 10) catch return .none;
        if (n == 0 or file_size == 0) return .unsatisfiable;
        const count = @min(n, file_size);
        return .{ .satisfiable = .{ .start = file_size - count, .end = file_size - 1 } };
    }

    const start = std.fmt.parseInt(u64, start_str, 10) catch return .none;
    // A first-byte position at or past EOF cannot be satisfied.
    if (start >= file_size) return .unsatisfiable;

    const end = if (end_str.len == 0)
        file_size - 1
    else blk: {
        const e = std.fmt.parseInt(u64, end_str, 10) catch return .none;
        if (e < start) return .none; // reversed bounds: invalid, ignore
        break :blk @min(e, file_size - 1); // clamp last-byte to EOF
    };

    return .{ .satisfiable = .{ .start = start, .end = end } };
}

/// Serve a single file with full HTTP features
pub fn serveFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    req: *http.Request,
    res: *http.Response,
    options: StaticFileOptions,
) !void {
    // Check if file exists and get stats
    const file_stat = fs.stat(res.io, file_path) catch {
        res.status_code = .NotFound;
        try res.text("File not found");
        return;
    };

    // Don't serve directories
    if (file_stat.kind == .directory) {
        res.status_code = .Forbidden;
        try res.text("Cannot serve directory");
        return;
    }

    // Check for dot files
    if (!options.dot_files) {
        const basename = std.fs.path.basename(file_path);
        if (basename.len > 0 and basename[0] == '.') {
            res.status_code = .Forbidden;
            try res.text("Hidden files not allowed");
            return;
        }
    }

    // mtime as whole Unix seconds (the stat clock is nanoseconds since the
    // epoch, i96). Used both for the conditional check and the Last-Modified
    // header below.
    const mtime_secs: i64 = @intCast(@divFloor(file_stat.mtime.nanoseconds, std.time.ns_per_s));

    // Calculate ETag
    var etag: ?[]u8 = null;
    defer if (etag) |e| allocator.free(e);

    if (options.enable_etag) {
        etag = try calculateETag(file_stat, allocator);

        // Check if client's cached version is valid
        if (checkNotModified(req, etag.?, mtime_secs)) {
            res.status_code = .NotModified;
            _ = try res.setHeader("ETag", etag.?);
            try res.send("");
            return;
        }
    }

    // Set MIME type
    const mime_type = getMimeType(file_path);
    _ = try res.setHeader("Content-Type", mime_type);

    // Set caching headers
    if (options.cache_control) |cc| {
        _ = try res.setHeader("Cache-Control", cc);
    }

    if (etag) |e| {
        _ = try res.setHeader("ETag", e);
    }

    // Last-Modified as an RFC 9110 IMF-fixdate. Reuses the canonical formatter
    // in http.zig rather than a second ad-hoc date implementation.
    const last_modified = try http.formatHttpDate(allocator, mtime_secs);
    defer allocator.free(last_modified);
    _ = try res.setHeader("Last-Modified", last_modified);

    // Handle Range requests
    if (options.enable_range) {
        // Advertise range support on every response for this resource.
        _ = try res.setHeader("Accept-Ranges", "bytes");

        if (req.getHeader("range")) |range_header| {
            switch (parseRange(range_header, file_stat.size)) {
                .satisfiable => |range_spec| return try serveRange(allocator, file_path, req, res, range_spec, file_stat.size),
                .unsatisfiable => {
                    // RFC 9110 §15.5.17: answer 416 and report the current
                    // length so the client can retry with a valid range.
                    res.status_code = .RangeNotSatisfiable;
                    var cr_buf: [64]u8 = undefined;
                    const cr = try std.fmt.bufPrint(&cr_buf, "bytes */{d}", .{file_stat.size});
                    _ = try res.setHeader("Content-Range", cr);
                    try res.text("Range Not Satisfiable");
                    return;
                },
                .none => {}, // fall through to the full 200 below
            }
        }
    }

    // Stream the whole file (200) without reading it into memory.
    var file = try fs.File.open(allocator, res.io, file_path, .{ .read = true });
    defer file.close();
    res.status_code = .OK;
    try res.sendFile(file.file, 0, @intCast(file_stat.size));
}

/// Serve a satisfiable byte range as 206 Partial Content, streaming the
/// selected bytes straight from disk rather than buffering the whole range.
fn serveRange(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    req: *http.Request,
    res: *http.Response,
    range: RangeSpec,
    file_size: u64,
) !void {
    _ = req;

    const content_length = range.end - range.start + 1;

    var file = try fs.File.open(allocator, res.io, file_path, .{ .read = true });
    defer file.close();

    res.status_code = .PartialContent;

    var content_range_buf: [128]u8 = undefined;
    const content_range = try std.fmt.bufPrint(
        &content_range_buf,
        "bytes {d}-{d}/{d}",
        .{ range.start, range.end, file_size },
    );
    _ = try res.setHeader("Content-Range", content_range);

    try res.sendFile(file.file, range.start, @intCast(content_length));
}

/// Serve static files from a directory
/// Maximum number of path components a served URL may normalize to. Real asset
/// trees are far shallower; a deeper request fails closed rather than doing
/// unbounded work for a hostile client.
const max_static_components = 256;

pub const StaticPathError = error{
    MalformedPercentEncoding,
    InvalidPathByte,
    PathTraversal,
    PathTooLong,
};

/// Percent-decode `src` into `dst`, returning the decoded slice. Rejects
/// malformed escapes and any decoded NUL or control byte — those have no place
/// in a filesystem path and are classic traversal/smuggling vectors.
fn percentDecode(src: []const u8, dst: []u8) ![]u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < src.len) {
        var byte: u8 = undefined;
        if (src[i] == '%') {
            if (i + 2 >= src.len) return StaticPathError.MalformedPercentEncoding;
            const hi = std.fmt.charToDigit(src[i + 1], 16) catch return StaticPathError.MalformedPercentEncoding;
            const lo = std.fmt.charToDigit(src[i + 2], 16) catch return StaticPathError.MalformedPercentEncoding;
            byte = (@as(u8, hi) << 4) | lo;
            i += 3;
        } else {
            byte = src[i];
            i += 1;
        }
        // Reject NUL, C0 controls, and DEL: never valid in a served path.
        if (byte < 0x20 or byte == 0x7f) return StaticPathError.InvalidPathByte;
        if (n >= dst.len) return StaticPathError.PathTooLong;
        dst[n] = byte;
        n += 1;
    }
    return dst[0..n];
}

/// Resolve the untrusted URL path `url_path` under `base_dir` into a confined
/// filesystem path written to `out`. The path is percent-decoded, any stray
/// query/fragment is stripped, and its components are lexically normalized
/// relative to `base_dir`: "." is dropped, ".." pops one component, and a ".."
/// that would escape above `base_dir` fails closed with `PathTraversal`. This
/// replaces the old `indexOf(path, "..")` substring test, which both rejected
/// legitimate names containing ".." and missed percent-encoded traversal.
///
/// Purely lexical — it does not resolve symlinks; that confinement is applied
/// after `open()` (via realpath) when static file I/O is restored.
fn resolveStaticPath(base_dir: []const u8, url_path: []const u8, out: []u8) ![]const u8 {
    // The parser already splits the query, but strip a fragment/query
    // defensively in case this is reached with a raw target.
    var raw = url_path;
    if (std.mem.indexOfScalar(u8, raw, '#')) |h| raw = raw[0..h];
    if (std.mem.indexOfScalar(u8, raw, '?')) |q| raw = raw[0..q];

    var decoded_buf: [std.fs.max_path_bytes]u8 = undefined;
    const decoded = try percentDecode(raw, &decoded_buf);

    // Normalize components relative to the base directory.
    var comps: [max_static_components][]const u8 = undefined;
    var depth: usize = 0;
    var it = std.mem.tokenizeScalar(u8, decoded, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (depth == 0) return StaticPathError.PathTraversal; // escapes base_dir
            depth -= 1;
            continue;
        }
        if (depth >= max_static_components) return StaticPathError.PathTooLong;
        comps[depth] = comp;
        depth += 1;
    }

    // Reassemble base_dir + "/" + surviving components.
    if (base_dir.len > out.len) return StaticPathError.PathTooLong;
    @memcpy(out[0..base_dir.len], base_dir);
    var len = base_dir.len;
    if (len > 0 and out[len - 1] == '/') len -= 1; // avoid a doubled separator
    for (comps[0..depth]) |comp| {
        if (len + 1 + comp.len > out.len) return StaticPathError.PathTooLong;
        out[len] = '/';
        len += 1;
        @memcpy(out[len..][0..comp.len], comp);
        len += comp.len;
    }
    return out[0..len];
}

pub fn serveStatic(
    base_path: []const u8,
    options: StaticFileOptions,
) http.RouteHandler {
    return struct {
        const base_path_const = base_path;
        const options_const = options;

        fn handler(req: *http.Request, res: *http.Response) !void {
            // Canonically confine the untrusted URL path within base_path.
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const resolved = resolveStaticPath(base_path_const, req.path, &path_buf) catch {
                res.status_code = .Forbidden;
                try res.text("Invalid path");
                return;
            };

            // A directory request (root or trailing slash) serves the index
            // file. `index` is developer-controlled config, appended to the
            // already-confined directory path.
            const wants_index = req.path.len == 0 or req.path[req.path.len - 1] == '/';
            if (wants_index) {
                if (options_const.index) |index_file| {
                    var index_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const full_path = try std.fmt.bufPrint(
                        &index_buf,
                        "{s}/{s}",
                        .{ resolved, index_file },
                    );
                    return try serveFile(req.allocator, full_path, req, res, options_const);
                }
            }

            try serveFile(req.allocator, resolved, req, res, options_const);
        }
    }.handler;
}

/// Get MIME type from file extension
pub fn getMimeType(file_path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, file_path, '.')) |dot_pos| {
        const ext = file_path[dot_pos + 1 ..];

        // Text
        if (std.mem.eql(u8, ext, "html")) return "text/html; charset=utf-8";
        if (std.mem.eql(u8, ext, "htm")) return "text/html; charset=utf-8";
        if (std.mem.eql(u8, ext, "css")) return "text/css; charset=utf-8";
        if (std.mem.eql(u8, ext, "js")) return "application/javascript; charset=utf-8";
        if (std.mem.eql(u8, ext, "mjs")) return "application/javascript; charset=utf-8";
        if (std.mem.eql(u8, ext, "json")) return "application/json; charset=utf-8";
        if (std.mem.eql(u8, ext, "xml")) return "application/xml; charset=utf-8";
        if (std.mem.eql(u8, ext, "txt")) return "text/plain; charset=utf-8";
        if (std.mem.eql(u8, ext, "md")) return "text/markdown; charset=utf-8";
        if (std.mem.eql(u8, ext, "csv")) return "text/csv; charset=utf-8";

        // Images
        if (std.mem.eql(u8, ext, "png")) return "image/png";
        if (std.mem.eql(u8, ext, "jpg")) return "image/jpeg";
        if (std.mem.eql(u8, ext, "jpeg")) return "image/jpeg";
        if (std.mem.eql(u8, ext, "gif")) return "image/gif";
        if (std.mem.eql(u8, ext, "svg")) return "image/svg+xml";
        if (std.mem.eql(u8, ext, "ico")) return "image/x-icon";
        if (std.mem.eql(u8, ext, "webp")) return "image/webp";
        if (std.mem.eql(u8, ext, "avif")) return "image/avif";
        if (std.mem.eql(u8, ext, "bmp")) return "image/bmp";

        // Fonts
        if (std.mem.eql(u8, ext, "woff")) return "font/woff";
        if (std.mem.eql(u8, ext, "woff2")) return "font/woff2";
        if (std.mem.eql(u8, ext, "ttf")) return "font/ttf";
        if (std.mem.eql(u8, ext, "otf")) return "font/otf";
        if (std.mem.eql(u8, ext, "eot")) return "application/vnd.ms-fontobject";

        // Audio/Video
        if (std.mem.eql(u8, ext, "mp3")) return "audio/mpeg";
        if (std.mem.eql(u8, ext, "mp4")) return "video/mp4";
        if (std.mem.eql(u8, ext, "webm")) return "video/webm";
        if (std.mem.eql(u8, ext, "ogg")) return "audio/ogg";
        if (std.mem.eql(u8, ext, "wav")) return "audio/wav";

        // Archives
        if (std.mem.eql(u8, ext, "pdf")) return "application/pdf";
        if (std.mem.eql(u8, ext, "zip")) return "application/zip";
        if (std.mem.eql(u8, ext, "tar")) return "application/x-tar";
        if (std.mem.eql(u8, ext, "gz")) return "application/gzip";
        if (std.mem.eql(u8, ext, "7z")) return "application/x-7z-compressed";

        // Special
        if (std.mem.eql(u8, ext, "wasm")) return "application/wasm";
        if (std.mem.eql(u8, ext, "manifest")) return "application/manifest+json";
    }

    return "application/octet-stream";
}

/// Create a static file handler for a specific directory
pub fn staticHandler(
    comptime base_dir: []const u8,
    comptime url_prefix: []const u8,
) http.RouteHandler {
    return struct {
        fn handler(req: *http.Request, res: *http.Response) !void {
            // Remove URL prefix from path
            const requested_path = if (std.mem.startsWith(u8, req.path, url_prefix))
                req.path[url_prefix.len..]
            else
                req.path;

            // Canonically confine the untrusted URL path within base_dir.
            // This percent-decodes and lexically normalizes the path, failing
            // closed on traversal — the old `indexOf(path, "..")` check both
            // missed percent-encoded `..` and rejected legitimate names.
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = resolveStaticPath(base_dir, requested_path, &path_buf) catch {
                res.status_code = .Forbidden;
                try res.text("Invalid path");
                return;
            };

            // Serve the file with default options
            const options = StaticFileOptions{};
            try serveFile(req.allocator, full_path, req, res, options);
        }
    }.handler;
}

test "mime type detection" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", getMimeType("index.html"));
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", getMimeType("app.js"));
    try std.testing.expectEqualStrings("image/png", getMimeType("logo.png"));
    try std.testing.expectEqualStrings("application/json; charset=utf-8", getMimeType("data.json"));
    try std.testing.expectEqualStrings("application/wasm", getMimeType("module.wasm"));
    try std.testing.expectEqualStrings("application/octet-stream", getMimeType("unknown.xyz"));
}

test "range parsing resolves absolute bounds and classifies each form" {
    // Explicit start-end.
    try std.testing.expectEqual(
        RangeResult{ .satisfiable = .{ .start = 0, .end = 499 } },
        parseRange("bytes=0-499", 1000),
    );

    // Open-ended: A- runs to EOF (inclusive last byte).
    try std.testing.expectEqual(
        RangeResult{ .satisfiable = .{ .start = 500, .end = 999 } },
        parseRange("bytes=500-", 1000),
    );

    // Suffix: the final N bytes.
    try std.testing.expectEqual(
        RangeResult{ .satisfiable = .{ .start = 500, .end = 999 } },
        parseRange("bytes=-500", 1000),
    );

    // A suffix larger than the file clamps to the whole file.
    try std.testing.expectEqual(
        RangeResult{ .satisfiable = .{ .start = 0, .end = 999 } },
        parseRange("bytes=-5000", 1000),
    );

    // An end past EOF clamps to the last byte rather than failing.
    try std.testing.expectEqual(
        RangeResult{ .satisfiable = .{ .start = 900, .end = 999 } },
        parseRange("bytes=900-100000", 1000),
    );

    // Start at/after EOF and a zero-length suffix are unsatisfiable → 416.
    try std.testing.expectEqual(RangeResult.unsatisfiable, parseRange("bytes=2000-3000", 1000));
    try std.testing.expectEqual(RangeResult.unsatisfiable, parseRange("bytes=1000-", 1000));
    try std.testing.expectEqual(RangeResult.unsatisfiable, parseRange("bytes=-0", 1000));

    // Unsupported unit, multi-range, reversed bounds, and junk are ignored so
    // the caller serves a full 200.
    try std.testing.expectEqual(RangeResult.none, parseRange("items=0-1", 1000));
    try std.testing.expectEqual(RangeResult.none, parseRange("bytes=0-1,2-3", 1000));
    try std.testing.expectEqual(RangeResult.none, parseRange("bytes=500-100", 1000));
    try std.testing.expectEqual(RangeResult.none, parseRange("invalid", 1000));
}

test "resolveStaticPath confines legitimate paths under base_dir" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = "/srv/www";

    // Root request resolves to the base directory itself.
    try std.testing.expectEqualStrings(base, try resolveStaticPath(base, "/", &buf));
    try std.testing.expectEqualStrings(base, try resolveStaticPath(base, "", &buf));

    // Ordinary nested paths.
    try std.testing.expectEqualStrings("/srv/www/index.html", try resolveStaticPath(base, "/index.html", &buf));
    try std.testing.expectEqualStrings("/srv/www/css/app.css", try resolveStaticPath(base, "/css/app.css", &buf));

    // "." segments and collapsed slashes are harmless.
    try std.testing.expectEqualStrings("/srv/www/a/b", try resolveStaticPath(base, "/a/./b", &buf));
    try std.testing.expectEqualStrings("/srv/www/a/b", try resolveStaticPath(base, "//a//b", &buf));

    // A ".." that stays within the tree is fine.
    try std.testing.expectEqualStrings("/srv/www/b", try resolveStaticPath(base, "/a/../b", &buf));

    // A trailing base separator does not produce a doubled slash.
    try std.testing.expectEqualStrings("/srv/www/x", try resolveStaticPath("/srv/www/", "/x", &buf));
}

test "resolveStaticPath rejects traversal and malformed input" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = "/srv/www";

    // Plain and nested traversal above the base.
    try std.testing.expectError(StaticPathError.PathTraversal, resolveStaticPath(base, "/../etc/passwd", &buf));
    try std.testing.expectError(StaticPathError.PathTraversal, resolveStaticPath(base, "/a/../../etc/passwd", &buf));
    try std.testing.expectError(StaticPathError.PathTraversal, resolveStaticPath(base, "/..", &buf));

    // Percent-encoded traversal: the old indexOf(path, "..") check missed this.
    try std.testing.expectError(StaticPathError.PathTraversal, resolveStaticPath(base, "/%2e%2e/etc/passwd", &buf));
    try std.testing.expectError(StaticPathError.PathTraversal, resolveStaticPath(base, "/%2e%2e%2fetc%2fpasswd", &buf));

    // NUL and control bytes (encoded) are rejected.
    try std.testing.expectError(StaticPathError.InvalidPathByte, resolveStaticPath(base, "/a%00b", &buf));
    try std.testing.expectError(StaticPathError.InvalidPathByte, resolveStaticPath(base, "/a%0ab", &buf));

    // Malformed percent escapes are rejected.
    try std.testing.expectError(StaticPathError.MalformedPercentEncoding, resolveStaticPath(base, "/a%2", &buf));
    try std.testing.expectError(StaticPathError.MalformedPercentEncoding, resolveStaticPath(base, "/a%zz", &buf));
}

test "resolveStaticPath does not confuse a prefix sibling for the base" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // A traversal that would land in a sibling sharing a name prefix must not
    // be treated as inside the base directory.
    try std.testing.expectError(
        StaticPathError.PathTraversal,
        resolveStaticPath("/srv/www", "/../www-secret/key", &buf),
    );
}

test "percentDecode rejects control bytes and truncated escapes" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("abc", try percentDecode("abc", &buf));
    try std.testing.expectEqualStrings("a/b", try percentDecode("a%2fb", &buf));
    try std.testing.expectError(StaticPathError.InvalidPathByte, percentDecode("a%00", &buf));
    try std.testing.expectError(StaticPathError.MalformedPercentEncoding, percentDecode("a%", &buf));
    try std.testing.expectError(StaticPathError.MalformedPercentEncoding, percentDecode("a%g0", &buf));
}

// ---- Integration: real file streaming over a loopback server ----
//
// These drive the actual serveFile/serveRange/sendFile path end to end against a
// temp file, so the streaming send and range framing are exercised (and forced
// to compile), not just the pure parsers above.

const it_payload = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"; // 26 bytes

// The fixture lives in a Zig-managed temp dir (`std.testing.tmpDir`, under
// `.zig-cache/tmp`). Its absolute path is published here so `serveItFile`, a
// route handler that takes no extra context, can locate it. Tests run serially,
// so this shared state is not raced.
var it_tmp: std.testing.TmpDir = undefined;
var it_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var it_file_path: []const u8 = &.{};

// Serves the fixed test file with ETag disabled so assertions focus on range
// framing and streaming rather than conditional-request behavior.
fn serveItFile(req: *http.Request, res: *http.Response) anyerror!void {
    try serveFile(req.allocator, it_file_path, req, res, .{ .enable_etag = false });
}

// Create a per-test temp dir, write the payload, and publish its absolute path.
fn setupItFile() !void {
    it_tmp = std.testing.tmpDir(.{});
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_abs = dir_buf[0..try it_tmp.dir.realPath(std.testing.io, &dir_buf)];
    it_file_path = try std.fmt.bufPrint(&it_path_buf, "{s}/static-it.bin", .{dir_abs});
    try fs.writeFile(std.testing.allocator, std.testing.io, it_file_path, it_payload);
}

fn teardownItFile() void {
    it_tmp.cleanup();
    it_file_path = &.{};
}

// Open a connection, send `request`, read until the server closes, return the
// full raw response (caller frees).
fn staticRoundTrip(allocator: std.mem.Allocator, port: u16, request: []const u8) ![]u8 {
    var client = try tcp.TcpClient.init(allocator);
    defer client.deinit();
    try client.connect("127.0.0.1", port);
    try client.write(request);

    var acc: std.ArrayList(u8) = .empty;
    errdefer acc.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = client.read(&buf) catch break;
        if (n == 0) break;
        try acc.appendSlice(allocator, buf[0..n]);
    }
    return acc.toOwnedSlice(allocator);
}

// The body is everything after the header terminator.
fn responseBody(resp: []const u8) []const u8 {
    const term = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return resp[resp.len..];
    return resp[term + 4 ..];
}

test "a full static GET streams the whole file with Content-Length and Accept-Ranges" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    try setupItFile();
    defer teardownItFile();

    var server = try http.Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/f", serveItFile);
    try server.start();
    const port = server.tcp_server.boundPort();

    const resp = try staticRoundTrip(allocator, port, "GET /f HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Length: 26") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Accept-Ranges: bytes") != null);
    try std.testing.expectEqualStrings(it_payload, responseBody(resp));
}

test "a byte-range static GET returns 206 and only the selected bytes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    try setupItFile();
    defer teardownItFile();

    var server = try http.Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/f", serveItFile);
    try server.start();
    const port = server.tcp_server.boundPort();

    const resp = try staticRoundTrip(allocator, port, "GET /f HTTP/1.1\r\nHost: t\r\nRange: bytes=0-4\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "206 Partial Content") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Range: bytes 0-4/26") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Length: 5") != null);
    try std.testing.expectEqualStrings("ABCDE", responseBody(resp));
}

test "a suffix-range static GET returns the final bytes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    try setupItFile();
    defer teardownItFile();

    var server = try http.Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/f", serveItFile);
    try server.start();
    const port = server.tcp_server.boundPort();

    const resp = try staticRoundTrip(allocator, port, "GET /f HTTP/1.1\r\nHost: t\r\nRange: bytes=-5\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "206 Partial Content") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Range: bytes 21-25/26") != null);
    try std.testing.expectEqualStrings("VWXYZ", responseBody(resp));
}

test "an unsatisfiable range static GET returns 416 with the current length" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    try setupItFile();
    defer teardownItFile();

    var server = try http.Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/f", serveItFile);
    try server.start();
    const port = server.tcp_server.boundPort();

    const resp = try staticRoundTrip(allocator, port, "GET /f HTTP/1.1\r\nHost: t\r\nRange: bytes=1000-2000\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "416 Range Not Satisfiable") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Range: bytes */26") != null);
}

test "a HEAD static request keeps Content-Length but sends no body" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    try setupItFile();
    defer teardownItFile();

    var server = try http.Server.init(allocator, .{ .port = 0, .host = "127.0.0.1", .worker_count = 1 });
    defer server.deinit();
    try server.route("GET", "/f", serveItFile);
    try server.start();
    const port = server.tcp_server.boundPort();

    const resp = try staticRoundTrip(allocator, port, "HEAD /f HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    defer allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Length: 26") != null);
    try std.testing.expectEqualStrings("", responseBody(resp));
}
