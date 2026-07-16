const std = @import("std");

const log = std.log.scoped(.otel);

/// OpenTelemetry Distributed Tracing Implementation
/// Specification: https://opentelemetry.io/docs/specs/otel/
/// Wall-clock timestamp in milliseconds since the Unix epoch.
///
/// std.time.milliTimestamp was removed in favour of the IO-provided clock;
/// read the wall clock through the global single-threaded provider.
fn nowMillis() i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
}

pub const Error = error{
    TracerNotInitialized,
    SpanNotFound,
    InvalidTraceId,
    InvalidSpanId,
    ExporterError,
};

/// Trace ID (128-bit / 16 bytes)
pub const TraceId = struct {
    bytes: [16]u8,

    pub fn generate() !TraceId {
        var id: TraceId = undefined;
        const io = std.Io.Threaded.global_single_threaded.io();
        try io.randomSecure(&id.bytes);
        return id;
    }

    pub fn fromHex(hex: []const u8) !TraceId {
        if (hex.len != 32) return Error.InvalidTraceId;
        var id: TraceId = undefined;
        _ = std.fmt.hexToBytes(&id.bytes, hex) catch return Error.InvalidTraceId;
        return id;
    }

    pub fn toHex(self: *const TraceId) [32]u8 {
        return std.fmt.bytesToHex(self.bytes, .lower);
    }

    pub fn isValid(self: *const TraceId) bool {
        for (self.bytes) |b| {
            if (b != 0) return true;
        }
        return false;
    }
};

/// Span ID (64-bit / 8 bytes)
pub const SpanId = struct {
    bytes: [8]u8,

    pub fn generate() !SpanId {
        var id: SpanId = undefined;
        const io = std.Io.Threaded.global_single_threaded.io();
        try io.randomSecure(&id.bytes);
        return id;
    }

    pub fn fromHex(hex: []const u8) !SpanId {
        if (hex.len != 16) return Error.InvalidSpanId;
        var id: SpanId = undefined;
        _ = std.fmt.hexToBytes(&id.bytes, hex) catch return Error.InvalidSpanId;
        return id;
    }

    pub fn toHex(self: *const SpanId) [16]u8 {
        return std.fmt.bytesToHex(self.bytes, .lower);
    }

    pub fn isValid(self: *const SpanId) bool {
        for (self.bytes) |b| {
            if (b != 0) return true;
        }
        return false;
    }
};

/// Span kind (type of operation)
pub const SpanKind = enum(u8) {
    internal = 0,
    server = 1,
    client = 2,
    producer = 3,
    consumer = 4,
};

/// Span status code
pub const StatusCode = enum(u8) {
    unset = 0,
    ok = 1,
    @"error" = 2,
};

/// Span status
pub const Status = struct {
    code: StatusCode = .unset,
    description: ?[]const u8 = null,
};

/// Attribute value types
pub const AttributeValue = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    string_array: []const []const u8,
    int_array: []const i64,
    float_array: []const f64,
    bool_array: []const bool,
};

/// Span attribute
pub const Attribute = struct {
    key: []const u8,
    value: AttributeValue,
};

/// Span event (annotation at a specific time)
pub const Event = struct {
    name: []const u8,
    timestamp: i64,
    attributes: []const Attribute = &[_]Attribute{},
};

/// Span link (reference to another span)
pub const Link = struct {
    trace_id: TraceId,
    span_id: SpanId,
    attributes: []const Attribute = &[_]Attribute{},
};

/// Trace context for propagation
pub const TraceContext = struct {
    trace_id: TraceId,
    span_id: SpanId,
    trace_flags: u8 = 0,
    trace_state: ?[]const u8 = null,

    /// W3C Trace Context header name
    pub const TRACEPARENT_HEADER = "traceparent";
    pub const TRACESTATE_HEADER = "tracestate";

    /// Parse W3C Trace Context from traceparent header
    /// Format: version-traceid-spanid-flags
    pub fn fromTraceparent(header: []const u8) !TraceContext {
        if (header.len < 55) return Error.InvalidTraceId;

        // Validate version (currently only 00 is supported)
        if (!std.mem.eql(u8, header[0..2], "00")) return Error.InvalidTraceId;
        if (header[2] != '-') return Error.InvalidTraceId;

        const trace_id = try TraceId.fromHex(header[3..35]);
        if (header[35] != '-') return Error.InvalidTraceId;

        const span_id = try SpanId.fromHex(header[36..52]);
        if (header[52] != '-') return Error.InvalidTraceId;

        const flags = std.fmt.parseInt(u8, header[53..55], 16) catch return Error.InvalidTraceId;

        return TraceContext{
            .trace_id = trace_id,
            .span_id = span_id,
            .trace_flags = flags,
        };
    }

    /// Format as W3C Trace Context traceparent header
    pub fn toTraceparent(self: *const TraceContext) [55]u8 {
        var buf: [55]u8 = undefined;

        // Version
        buf[0] = '0';
        buf[1] = '0';
        buf[2] = '-';

        // Trace ID
        const trace_hex = self.trace_id.toHex();
        @memcpy(buf[3..35], &trace_hex);
        buf[35] = '-';

        // Span ID
        const span_hex = self.span_id.toHex();
        @memcpy(buf[36..52], &span_hex);
        buf[52] = '-';

        // Flags
        _ = std.fmt.bufPrint(buf[53..55], "{x:0>2}", .{self.trace_flags}) catch unreachable;

        return buf;
    }

    /// Check if trace is sampled
    pub fn isSampled(self: *const TraceContext) bool {
        return (self.trace_flags & 0x01) != 0;
    }
};

/// Span represents a single operation within a trace
pub const Span = struct {
    name: []const u8,
    trace_id: TraceId,
    span_id: SpanId,
    parent_span_id: ?SpanId = null,
    kind: SpanKind = .internal,
    start_time: i64,
    end_time: ?i64 = null,
    status: Status = .{},
    attributes: std.ArrayList(Attribute),
    events: std.ArrayList(Event),
    links: std.ArrayList(Link),
    is_recording: bool = true,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, trace_id: TraceId) !Span {
        return Span{
            .name = name,
            .trace_id = trace_id,
            .span_id = try SpanId.generate(),
            .start_time = nowMillis(),
            .attributes = .empty,
            .events = .empty,
            .links = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Span) void {
        self.attributes.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.links.deinit(self.allocator);
    }

    /// End the span
    pub fn end(self: *Span) void {
        if (self.end_time == null) {
            self.end_time = nowMillis();
        }
    }

    /// Set span attribute
    pub fn setAttribute(self: *Span, key: []const u8, value: AttributeValue) !void {
        if (!self.is_recording) return;
        try self.attributes.append(self.allocator, Attribute{ .key = key, .value = value });
    }

    /// Set multiple attributes
    pub fn setAttributes(self: *Span, attrs: []const Attribute) !void {
        if (!self.is_recording) return;
        try self.attributes.appendSlice(self.allocator, attrs);
    }

    /// Add an event
    pub fn addEvent(self: *Span, name: []const u8) !void {
        if (!self.is_recording) return;
        try self.events.append(self.allocator, Event{
            .name = name,
            .timestamp = nowMillis(),
        });
    }

    /// Add an event with attributes
    pub fn addEventWithAttributes(self: *Span, name: []const u8, attrs: []const Attribute) !void {
        if (!self.is_recording) return;
        try self.events.append(self.allocator, Event{
            .name = name,
            .timestamp = nowMillis(),
            .attributes = attrs,
        });
    }

    /// Set span status
    pub fn setStatus(self: *Span, code: StatusCode, description: ?[]const u8) void {
        self.status = Status{
            .code = code,
            .description = description,
        };
    }

    /// Record an exception
    pub fn recordException(self: *Span, err: anyerror) !void {
        try self.addEventWithAttributes("exception", &[_]Attribute{
            .{ .key = "exception.type", .value = .{ .string = @errorName(err) } },
        });
        self.setStatus(.@"error", @errorName(err));
    }

    /// Get trace context for propagation
    pub fn getContext(self: *const Span) TraceContext {
        return TraceContext{
            .trace_id = self.trace_id,
            .span_id = self.span_id,
            .trace_flags = 0x01, // Sampled
        };
    }

    /// Get duration in milliseconds
    pub fn getDuration(self: *const Span) ?i64 {
        if (self.end_time) |end_val| {
            return end_val - self.start_time;
        }
        return null;
    }
};

/// Span exporter interface
pub const SpanExporter = struct {
    exportFn: *const fn (spans: []const *Span) anyerror!void,
    shutdownFn: *const fn () void,

    pub fn @"export"(self: *const SpanExporter, spans: []const *Span) !void {
        try self.exportFn(spans);
    }

    pub fn shutdown(self: *const SpanExporter) void {
        self.shutdownFn();
    }
};

/// Console exporter (for debugging)
pub const ConsoleExporter = struct {
    pub fn getExporter() SpanExporter {
        return SpanExporter{
            .exportFn = exportSpans,
            .shutdownFn = shutdown,
        };
    }

    fn exportSpans(spans: []const *Span) !void {
        for (spans) |span| {
            const trace_hex = span.trace_id.toHex();
            const span_hex = span.span_id.toHex();
            const duration = span.getDuration() orelse 0;

            std.debug.print("[TRACE] {s} trace_id={s} span_id={s} duration={d}ms\n", .{
                span.name,
                &trace_hex,
                &span_hex,
                duration,
            });

            for (span.attributes.items) |attr| {
                std.debug.print("  {s}=", .{attr.key});
                switch (attr.value) {
                    .string => |s| std.debug.print("{s}\n", .{s}),
                    .int => |i| std.debug.print("{d}\n", .{i}),
                    .float => |f| std.debug.print("{d}\n", .{f}),
                    .bool => |b| std.debug.print("{}\n", .{b}),
                    else => std.debug.print("...\n", .{}),
                }
            }
        }
    }

    fn shutdown() void {}
};

/// OTLP HTTP exporter (sends to OpenTelemetry Collector)
pub const OtlpHttpExporter = struct {
    endpoint: []const u8,
    headers: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) OtlpHttpExporter {
        return OtlpHttpExporter{
            .endpoint = endpoint,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OtlpHttpExporter) void {
        self.headers.deinit();
    }

    pub fn setHeader(self: *OtlpHttpExporter, key: []const u8, value: []const u8) !void {
        try self.headers.put(key, value);
    }

    pub fn getExporter(self: *OtlpHttpExporter) SpanExporter {
        _ = self;
        return SpanExporter{
            .exportFn = exportSpans,
            .shutdownFn = shutdown,
        };
    }

    fn exportSpans(spans: []const *Span) !void {
        // In a real implementation, this would:
        // 1. Serialize spans to OTLP protobuf or JSON format
        // 2. Send HTTP POST to the collector endpoint
        // 3. Handle retries and backoff

        // For now, just log that we would export
        std.debug.print("[OTLP] Would export {d} spans\n", .{spans.len});
    }

    fn shutdown() void {}
};

/// Sampler interface with context support for configurable samplers
pub const Sampler = struct {
    ctx: *const anyopaque,
    shouldSampleFn: *const fn (ctx: *const anyopaque, trace_id: TraceId, name: []const u8) bool,

    pub fn shouldSample(self: *const Sampler, trace_id: TraceId, name: []const u8) bool {
        return self.shouldSampleFn(self.ctx, trace_id, name);
    }
};

/// Always sample
pub const AlwaysOnSampler = struct {
    const Self = @This();
    const instance: Self = .{};

    pub fn getSampler() Sampler {
        return Sampler{
            .ctx = @ptrCast(&instance),
            .shouldSampleFn = shouldSample,
        };
    }

    fn shouldSample(_: *const anyopaque, _: TraceId, _: []const u8) bool {
        return true;
    }
};

/// Never sample
pub const AlwaysOffSampler = struct {
    const Self = @This();
    const instance: Self = .{};

    pub fn getSampler() Sampler {
        return Sampler{
            .ctx = @ptrCast(&instance),
            .shouldSampleFn = shouldSample,
        };
    }

    fn shouldSample(_: *const anyopaque, _: TraceId, _: []const u8) bool {
        return false;
    }
};

/// Probability-based sampler using trace ID for deterministic sampling
pub const TraceIdRatioSampler = struct {
    ratio: f64,
    const Self = @This();

    pub fn init(ratio: f64) TraceIdRatioSampler {
        return TraceIdRatioSampler{
            .ratio = std.math.clamp(ratio, 0.0, 1.0),
        };
    }

    pub fn getSampler(self: *const Self) Sampler {
        return Sampler{
            .ctx = @ptrCast(self),
            .shouldSampleFn = shouldSample,
        };
    }

    fn shouldSample(ctx: *const anyopaque, trace_id: TraceId, _: []const u8) bool {
        const self: *const Self = @ptrCast(@alignCast(ctx));
        // Use last 8 bytes of trace ID as random value for deterministic sampling
        const rand_bytes = trace_id.bytes[8..16];
        const rand_value = std.mem.readInt(u64, rand_bytes, .big);
        const normalized = @as(f64, @floatFromInt(rand_value)) / @as(f64, @floatFromInt(std.math.maxInt(u64)));
        return normalized < self.ratio;
    }
};

/// Tracer provider (creates and manages tracers)
pub const TracerProvider = struct {
    resource: Resource,
    exporter: ?SpanExporter = null,
    sampler: Sampler,
    spans: std.ArrayList(*Span),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !TracerProvider {
        return TracerProvider{
            .resource = try Resource.init(allocator),
            .sampler = AlwaysOnSampler.getSampler(),
            .spans = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TracerProvider) void {
        // A final flush best-effort exports pending spans on shutdown. deinit
        // cannot fail, so an export error is logged rather than propagated; the
        // loop below still frees every span, so memory is reclaimed regardless.
        self.flush() catch |err| {
            log.warn("final span flush on deinit failed: {s}", .{@errorName(err)});
        };
        for (self.spans.items) |span| {
            span.deinit();
            self.allocator.destroy(span);
        }
        self.spans.deinit(self.allocator);
        self.resource.deinit();
    }

    pub fn setExporter(self: *TracerProvider, exporter: SpanExporter) void {
        self.exporter = exporter;
    }

    pub fn setSampler(self: *TracerProvider, sampler: Sampler) void {
        self.sampler = sampler;
    }

    /// Get a tracer
    pub fn getTracer(self: *TracerProvider, name: []const u8) Tracer {
        return Tracer{
            .name = name,
            .provider = self,
        };
    }

    /// Flush all pending spans to exporter
    pub fn flush(self: *TracerProvider) !void {
        if (self.exporter) |exporter| {
            try exporter.@"export"(self.spans.items);
        }
        // Clear processed spans
        for (self.spans.items) |span| {
            span.deinit();
            self.allocator.destroy(span);
        }
        self.spans.clearRetainingCapacity();
    }

    fn recordSpan(self: *TracerProvider, span: *Span) !void {
        try self.spans.append(self.allocator, span);
    }
};

/// Resource describes the entity producing telemetry
pub const Resource = struct {
    attributes: std.StringHashMap(AttributeValue),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Resource {
        var res = Resource{
            .attributes = std.StringHashMap(AttributeValue).init(allocator),
            .allocator = allocator,
        };
        errdefer res.attributes.deinit();

        // Set default attributes
        try res.attributes.put("service.name", .{ .string = "unknown_service" });
        try res.attributes.put("telemetry.sdk.name", .{ .string = "nexus-otel" });
        try res.attributes.put("telemetry.sdk.language", .{ .string = "zig" });
        try res.attributes.put("telemetry.sdk.version", .{ .string = @import("build_options").version });

        return res;
    }

    pub fn deinit(self: *Resource) void {
        self.attributes.deinit();
    }

    pub fn setAttribute(self: *Resource, key: []const u8, value: AttributeValue) !void {
        try self.attributes.put(key, value);
    }
};

/// Tracer creates spans
pub const Tracer = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    provider: *TracerProvider,

    /// Start a new span
    pub fn startSpan(self: *Tracer, name: []const u8) !*Span {
        const trace_id = try TraceId.generate();

        // Check sampling
        if (!self.provider.sampler.shouldSample(trace_id, name)) {
            // Return a non-recording span
            const span = try self.provider.allocator.create(Span);
            span.* = try Span.init(self.provider.allocator, name, trace_id);
            span.is_recording = false;
            return span;
        }

        const span = try self.provider.allocator.create(Span);
        span.* = try Span.init(self.provider.allocator, name, trace_id);
        return span;
    }

    /// Start a span with parent context
    pub fn startSpanWithContext(self: *Tracer, name: []const u8, parent: TraceContext) !*Span {
        const span = try self.provider.allocator.create(Span);
        span.* = try Span.init(self.provider.allocator, name, parent.trace_id);
        span.parent_span_id = parent.span_id;
        return span;
    }

    /// End span and record it
    pub fn endSpan(self: *Tracer, span: *Span) !void {
        span.end();
        if (span.is_recording) {
            try self.provider.recordSpan(span);
        } else {
            span.deinit();
            self.provider.allocator.destroy(span);
        }
    }
};

/// Convenience function for HTTP request tracing
pub fn traceHttpRequest(
    tracer: *Tracer,
    method: []const u8,
    path: []const u8,
    parent_context: ?TraceContext,
) !*Span {
    const span_name = blk: {
        var buf: [256]u8 = undefined;
        break :blk std.fmt.bufPrint(&buf, "{s} {s}", .{ method, path }) catch "HTTP Request";
    };

    const span = if (parent_context) |ctx|
        try tracer.startSpanWithContext(span_name, ctx)
    else
        try tracer.startSpan(span_name);

    span.kind = .server;

    try span.setAttribute("http.method", .{ .string = method });
    try span.setAttribute("http.target", .{ .string = path });

    return span;
}

// Tests
test "trace id generation" {
    const id = try TraceId.generate();
    try std.testing.expect(id.isValid());

    const hex = id.toHex();
    try std.testing.expectEqual(@as(usize, 32), hex.len);
}

test "trace context parsing" {
    const header = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    const ctx = try TraceContext.fromTraceparent(header);

    try std.testing.expect(ctx.trace_id.isValid());
    try std.testing.expect(ctx.span_id.isValid());
    try std.testing.expect(ctx.isSampled());
}

test "trace context formatting" {
    var ctx = TraceContext{
        .trace_id = try TraceId.generate(),
        .span_id = try SpanId.generate(),
        .trace_flags = 0x01,
    };

    const header = ctx.toTraceparent();
    try std.testing.expectEqual(@as(usize, 55), header.len);
    try std.testing.expectEqualStrings("00-", header[0..3]);
}

test "span creation" {
    const allocator = std.testing.allocator;

    var provider = try TracerProvider.init(allocator);
    defer provider.deinit();

    var tracer = provider.getTracer("test-tracer");

    const span = try tracer.startSpan("test-operation");
    try span.setAttribute("key", .{ .string = "value" });
    try tracer.endSpan(span);
}

test "repeated tracer provider create/span/destroy cycles are leak-free" {
    // Phase 2 exit gate: build a provider, emit an attributed span, and tear
    // everything down many times. Confirms the default resource attributes, the
    // span/attribute allocations, and the process-lifetime global io accessor
    // leave nothing behind per cycle under the leak-detecting allocator.
    const allocator = std.testing.allocator;

    var cycle: usize = 0;
    while (cycle < 256) : (cycle += 1) {
        var provider = try TracerProvider.init(allocator);
        defer provider.deinit();

        var tracer = provider.getTracer("test-tracer");

        const span = try tracer.startSpan("test-operation");
        try span.setAttribute("key", .{ .string = "value" });
        try span.setAttribute("count", .{ .int = @intCast(cycle) });
        try tracer.endSpan(span);
    }
}
