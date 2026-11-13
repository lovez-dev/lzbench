const std = @import("std");

const Timer = struct {
    io: std.Io,
    started: std.Io.Timestamp,

    pub fn reset(self: *Timer) void {
        self.started = std.Io.Clock.awake.now(self.io);
    }

    pub fn read(self: *const Timer) u64 {
        return @intCast(self.started.durationTo(std.Io.Clock.awake.now(self.io)).nanoseconds);
    }
};
const Allocator = std.mem.Allocator;

// Number of per-operation measurements retained in Result.
pub const SAMPLE_SIZE = 10_000;

/// Controls warmup and measured batches for runConfigured.
pub const Config = struct {
    /// Unmeasured workload calls used to warm caches and runtime state.
    warmup_batches: usize = 5,
    /// Operations requested from the workload in each batch.
    batch_size: usize = 1000,
    /// Number of batch-average samples per round.
    sample_count: usize = 30,
    /// Repeated batches combined into one sample to amortize clock overhead.
    batch_repeats: usize = 10,
    /// Calibration target per sample. Doubles repeats until reached, then fixes
    /// repeats for the round. Actual sample duration may vary. Zero skips calibration.
    min_sample_ns: u64 = 10 * std.time.ns_per_ms,
    /// Rounds in the same process; each warms up and calibrates independently.
    rounds: usize = 5,
    /// Workload allocator; defaults to page_allocator. The runner never resets it.
    allocator: ?Allocator = null,
    /// Counts cumulative requested bytes, including successful allocation growth.
    /// When enabled, wraps allocations and may perturb allocator benchmarks.
    count_allocations: bool = false,
};
pub const Result = struct {
    /// Sum of all timed batch durations in nanoseconds.
    total_ns: u64,
    /// Number of operations included in timed samples.
    operations: u64,
    /// Requested bytes during measured work; warmup and calibration are excluded.
    allocation_bytes: usize,
    /// Distinguishes disabled accounting from a measured zero allocation count.
    allocations_measured: bool = false,
    /// Largest per-operation sample in this run.
    worst_ns: f64,
    /// Smallest retained sample.
    min_ns: f64,
    /// Largest retained sample.
    max_ns: f64,
    /// Number of valid sorted entries in _samples.
    sample_count: usize,
    _samples: [SAMPLE_SIZE]f64,

    pub fn print(self: *const Result, name: []const u8) void {
        std.debug.print("{s}\n", .{name});
        std.debug.print("  {d:.3}ns/op sample mean; {d:.3}ns/op overall across {d} operations\n", .{ self.mean(), self.overallMean(), self.operations });
        if (!self.allocations_measured) {
            std.debug.print("  requested bytes/op: not measured (enable count_allocations)\n", .{});
        } else {
            std.debug.print("  {d:.2} requested bytes/op\n", .{@as(f64, @floatFromInt(self.allocation_bytes)) / @as(f64, @floatFromInt(self.operations))});
        }
        std.debug.print("  batch-average samples: {d}; median: {d:.3}ns/op; p95: {d:.3}ns/op; range: {d:.3}-{d:.3}ns/op; stddev: {d:.3}ns\n\n", .{ self.sample_count, self.median(), self.percentile(95), self.min_ns, self.max_ns, self.stdDev() });
    }

    /// Sorted per-operation sample values, in nanoseconds.
    pub fn samples(self: *const Result) []const f64 {
        return self._samples[0..self.sample_count];
    }

    /// Unweighted arithmetic mean of retained ns/op samples, matching stdDev.
    pub fn mean(self: *const Result) f64 {
        return meanSamples(self.samples());
    }

    /// Operation-weighted mean across all measured work, including all rounds.
    pub fn overallMean(self: *const Result) f64 {
        return @as(f64, @floatFromInt(self.total_ns)) / @as(f64, @floatFromInt(self.operations));
    }

    /// Median of the retained per-operation samples.
    pub fn median(self: *const Result) f64 {
        const values = self.samples();
        const middle = values.len / 2;
        if (values.len % 2 == 1) return values[middle];
        return (values[middle - 1] + values[middle]) / 2;
    }

    /// Nearest-rank percentile of retained samples; p must be between 0 and 100.
    pub fn percentile(self: *const Result, comptime p: u8) f64 {
        return percentileValue(self.samples(), p);
    }

    /// Coefficient of variation (sample standard deviation / mean).
    pub fn coefficientOfVariation(self: *const Result) f64 {
        const average = self.mean();
        return if (average == 0) 0 else self.stdDev() / average;
    }

    /// Sample standard deviation across retained per-operation samples.
    pub fn stdDev(self: *const Result) f64 {
        const s = self.samples();
        if (s.len < 2) return 0;
        const m = meanSamples(s);
        var total: f64 = 0;
        for (s) |value| {
            const delta = value - m;
            total += delta * delta;
        }
        return std.math.sqrt(total / @as(f64, @floatFromInt(s.len - 1)));
    }

    fn meanSamples(values: []const f64) f64 {
        var total: f64 = 0;
        for (values) |value| total += value;
        return total / @as(f64, @floatFromInt(values.len));
    }

    fn percentileValue(values: []const f64, comptime p: u8) f64 {
        if (values.len == 0 or p > 100) return std.math.nan(f64);
        if (p == 0) return values[0];
        const index = (@as(u128, values.len) * p + 99) / 100 - 1;
        return values[@intCast(index)];
    }
};

pub const Workload = *const fn (Allocator, usize) anyerror!void;

/// Runs warmups, then collects sorted per-operation timings from repeated batches.
pub fn runConfigured(io: std.Io, config: Config, workload: Workload) !Result {
    return runRepeated(io, config, workload, config.rounds);
}

fn runSingleConfigured(io: std.Io, config: Config, workload: Workload) !Result {
    if (config.batch_size == 0 or config.sample_count == 0 or config.sample_count > SAMPLE_SIZE or config.batch_repeats == 0 or config.rounds == 0 or config.batch_size > std.math.maxInt(usize) / config.batch_repeats or config.batch_size * config.batch_repeats > std.math.maxInt(u64)) return error.InvalidConfig;
    const parent_allocator = config.allocator orelse std.heap.page_allocator;
    var counter = CountingAllocator{ .parent = parent_allocator };
    const tracked_allocator = if (config.count_allocations) counter.allocator() else parent_allocator;
    const allocator = tracked_allocator;
    for (0..config.warmup_batches) |_| try workload(allocator, config.batch_size);
    counter.bytes = 0;

    var timer = Timer{ .io = io, .started = std.Io.Clock.awake.now(io) };
    var repeats = config.batch_repeats;
    if (config.min_sample_ns != 0) {
        while (true) {
            timer.reset();
            for (0..repeats) |_| try workload(allocator, config.batch_size);
            const elapsed = timer.read();
            // Calibration is additional unmeasured work, just like warmup.
            counter.bytes = 0;
            if (elapsed >= config.min_sample_ns) break;
            repeats = try growRepeats(repeats, config.batch_size);
        }
    }
    const operations: u64 = @intCast(config.batch_size * repeats);
    var result: Result = .{ .total_ns = 0, .operations = 0, .allocation_bytes = 0, .worst_ns = 0, .min_ns = std.math.floatMax(f64), .max_ns = 0, .sample_count = config.sample_count, ._samples = @splat(0.0) };
    for (0..config.sample_count) |sample_index| {
        timer.reset();
        for (0..repeats) |_| try workload(allocator, config.batch_size);
        const batch_ns = timer.read();
        const per_op = @as(f64, @floatFromInt(batch_ns)) / @as(f64, @floatFromInt(operations));
        result._samples[sample_index] = per_op;
        result.operations = try std.math.add(u64, result.operations, operations);
        result.total_ns = try std.math.add(u64, result.total_ns, batch_ns);
        result.min_ns = @min(result.min_ns, per_op);
        result.max_ns = @max(result.max_ns, per_op);
        result.worst_ns = result.max_ns;
    }
    result.allocation_bytes = if (config.count_allocations) counter.bytes else 0;
    result.allocations_measured = config.count_allocations;
    std.sort.heap(f64, result._samples[0..result.sample_count], {}, sampleLessThan);
    return result;
}

fn growRepeats(repeats: usize, batch_size: usize) !usize {
    const next = std.math.mul(usize, repeats, 2) catch return error.CalibrationOverflow;
    const operations = std.math.mul(usize, next, batch_size) catch return error.CalibrationOverflow;
    if (operations > std.math.maxInt(u64)) return error.CalibrationOverflow;
    return next;
}
/// Runs rounds in the same process and combines their sorted samples.
pub fn runRepeated(io: std.Io, config: Config, workload: Workload, rounds: usize) !Result {
    if (rounds == 0 or config.sample_count == 0 or config.sample_count > SAMPLE_SIZE or rounds > SAMPLE_SIZE / config.sample_count) return error.InvalidConfig;
    var combined: Result = .{ .total_ns = 0, .operations = 0, .allocation_bytes = 0, .worst_ns = 0, .min_ns = std.math.floatMax(f64), .max_ns = 0, .sample_count = 0, ._samples = @splat(0) };
    for (0..rounds) |_| {
        var adjusted = config;
        adjusted.rounds = 1;
        var result = try runSingleConfigured(io, adjusted, workload);
        combined.total_ns = try std.math.add(u64, combined.total_ns, result.total_ns);
        combined.operations = try std.math.add(u64, combined.operations, result.operations);
        combined.allocation_bytes = try std.math.add(usize, combined.allocation_bytes, result.allocation_bytes);
        combined.allocations_measured = result.allocations_measured;
        for (result.samples()) |sample| {
            combined._samples[combined.sample_count] = sample;
            combined.sample_count += 1;
        }
        combined.min_ns = @min(combined.min_ns, result.min_ns);
        combined.max_ns = @max(combined.max_ns, result.max_ns);
        combined.worst_ns = combined.max_ns;
    }
    std.sort.heap(f64, combined._samples[0..combined.sample_count], {}, sampleLessThan);
    return combined;
}
const CountingAllocator = struct {
    parent: Allocator,
    bytes: usize = 0,
    fn allocator(self: *@This()) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawAlloc(len, alignment, ret) orelse return null;
        self.bytes += len;
        return ptr;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (!self.parent.rawResize(memory, alignment, len, ret)) return false;
        self.bytes += len -| memory.len;
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawRemap(memory, alignment, len, ret) orelse return null;
        self.bytes += len -| memory.len;
        return ptr;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ret);
    }
};
fn sampleLessThan(context: void, lhs: f64, rhs: f64) bool {
    _ = context;
    return lhs < rhs;
}

test "configured benchmark performs warmups and batches" {
    const state = struct {
        var calls: usize = 0;
        fn workload(_: Allocator, operations: usize) !void {
            calls += 1;
            std.mem.doNotOptimizeAway(operations);
        }
    };
    state.calls = 0;
    const result = try runConfigured(std.testing.io, .{ .warmup_batches = 2, .batch_size = 5, .sample_count = 3, .batch_repeats = 2, .rounds = 3, .min_sample_ns = 0 }, state.workload);
    try std.testing.expectEqual(@as(usize, 24), state.calls);
    try std.testing.expectEqual(@as(usize, 9), result.sample_count);
    try std.testing.expectEqual(@as(u64, 90), result.operations);
}

test "batch statistics and cumulative allocation accounting" {
    var result: Result = .{ .total_ns = 8, .operations = 2, .allocation_bytes = 0, .worst_ns = 5, .min_ns = 3, .max_ns = 5, .sample_count = 2, ._samples = @splat(0.0) };
    result._samples[0] = 3.0;
    result._samples[1] = 5.0;
    try std.testing.expectEqual(@as(f64, 4), result.mean());
    try std.testing.expectEqual(@as(f64, 4), result.median());
    try std.testing.expectEqual(@as(f64, 5), result.percentile(95));
    try std.testing.expectEqual(@as(f64, @sqrt(2)), result.stdDev());
    var counter: CountingAllocator = .{ .parent = std.testing.allocator };
    const allocator = counter.allocator();
    const buffer = try allocator.alloc(u8, 4096);
    allocator.free(buffer);
    try std.testing.expectEqual(@as(usize, 4096), counter.bytes);
}

test "sub-nanosecond samples and zero percentile are preserved" {
    var result: Result = .{ .total_ns = 1, .operations = 2, .allocation_bytes = 0, .worst_ns = 0.5, .min_ns = 0.5, .max_ns = 0.5, .sample_count = 2, ._samples = @splat(0.5) };
    try std.testing.expectEqual(@as(f64, 0.5), result.samples()[0]);
    try std.testing.expectEqual(@as(f64, 0.5), result.percentile(0));
    try std.testing.expectEqual(@as(f64, 0.5), result.median());
}

test "mean uses retained fractional samples" {
    const result: Result = .{ .total_ns = 1, .operations = 2, .allocation_bytes = 0, .worst_ns = 0.5, .min_ns = 0.5, .max_ns = 0.5, .sample_count = 2, ._samples = @splat(0.5) };
    try std.testing.expectEqual(@as(f64, 0.5), result.mean());
}

test "calibration and warmup allocations are excluded from fixed-size samples" {
    const state = struct {
        var calls: u64 = 0;
        fn workload(allocator: Allocator, operations: usize) !void {
            calls += 1;
            for (0..operations) |_| {
                const buffer = try allocator.alloc(u8, 16);
                std.mem.doNotOptimizeAway(buffer);
                allocator.free(buffer);
            }
        }
    };
    state.calls = 0;
    const result = try runConfigured(std.testing.io, .{
        .allocator = std.testing.allocator,
        .count_allocations = true,
        .warmup_batches = 2,
        .batch_size = 3,
        .batch_repeats = 1,
        .sample_count = 3,
        .rounds = 1,
        .min_sample_ns = 100 * std.time.ns_per_us,
    }, state.workload);
    try std.testing.expect(result.allocations_measured);
    try std.testing.expectEqual(result.operations * 16, result.allocation_bytes);
    try std.testing.expectEqual(@as(u64, 0), result.operations % 9);
    try std.testing.expect(state.calls > 2 + result.operations / 3);
    // All samples in this round have identical operation counts.
    try std.testing.expectApproxEqRel(result.mean(), result.overallMean(), 1e-12);
}

test "invalid configurations fail before calling workload" {
    const callback = struct {
        fn workload(_: Allocator, _: usize) !void {
            return error.UnexpectedWorkloadCall;
        }
    }.workload;
    const configs = [_]Config{
        .{ .batch_size = 0 },
        .{ .batch_repeats = 0 },
        .{ .sample_count = 0 },
        .{ .rounds = 0 },
        .{ .sample_count = SAMPLE_SIZE + 1 },
        .{ .sample_count = SAMPLE_SIZE, .rounds = 2 },
        .{ .batch_size = std.math.maxInt(usize), .batch_repeats = 2 },
    };
    for (configs) |config| {
        try std.testing.expectError(error.InvalidConfig, runConfigured(std.testing.io, config, callback));
    }
    try std.testing.expectError(error.CalibrationOverflow, growRepeats(std.math.maxInt(usize), 1));
    try std.testing.expectError(error.CalibrationOverflow, growRepeats(1, std.math.maxInt(usize)));
}

test "overall mean weights operations instead of samples" {
    var result: Result = .{ .total_ns = 100, .operations = 30, .allocation_bytes = 0, .worst_ns = 4, .min_ns = 2, .max_ns = 4, .sample_count = 2, ._samples = @splat(0) };
    result._samples[0] = 2;
    result._samples[1] = 4;
    try std.testing.expectEqual(@as(f64, 3), result.mean());
    try std.testing.expectEqual(@as(f64, 100.0 / 30.0), result.overallMean());
}

test "synthetic clock verifies calibration timing and accounting exactly" {
    const state = struct {
        var time: i96 = 0;
        var reads: usize = 0;
        var calls: usize = 0;
        fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const value = time;
            time += 3; // Explicit clock overhead, independent of machine speed.
            reads += 1;
            return .{ .nanoseconds = value };
        }
        fn workload(allocator: Allocator, operations: usize) !void {
            calls += 1;
            time += @as(i96, @intCast(operations)) * 7;
            const buffer = try allocator.alloc(u8, operations * 16);
            allocator.free(buffer);
        }
    };
    state.time = 0;
    state.reads = 0;
    state.calls = 0;
    var vtable = std.testing.io.vtable.*;
    vtable.now = state.now;
    var io = std.testing.io;
    io.vtable = &vtable;
    const result = try runConfigured(io, .{
        .allocator = std.testing.allocator,
        .count_allocations = true,
        .warmup_batches = 2,
        .batch_size = 3,
        .batch_repeats = 1,
        .sample_count = 3,
        .rounds = 1,
        .min_sample_ns = 100,
    }, state.workload);
    // Calibration: 1, 2, 4, 8 calls (24, 45, 87, 171ns).
    // Measured samples: 8 calls * 3 operations * 7ns + 3ns clock overhead.
    try std.testing.expectEqual(@as(usize, 2 + 15 + 24), state.calls);
    try std.testing.expectEqual(@as(usize, 1 + 8 + 6), state.reads);
    try std.testing.expectEqual(@as(u64, 72), result.operations);
    try std.testing.expectEqual(@as(u64, 513), result.total_ns);
    try std.testing.expectEqual(@as(usize, 72 * 16), result.allocation_bytes);
    for (result.samples()) |sample| try std.testing.expectEqual(@as(f64, 7.125), sample);
}

test "workload errors propagate from warmup calibration and measurement" {
    const state = struct {
        var calls: usize = 0;
        var fail_at: usize = 0;
        fn workload(allocator: Allocator, _: usize) !void {
            const buffer = try allocator.alloc(u8, 16);
            defer allocator.free(buffer);
            calls += 1;
            if (calls == fail_at) return error.WorkloadFailed;
        }
    };
    const configs = [_]Config{
        .{ .warmup_batches = 1, .min_sample_ns = 0 },
        .{ .warmup_batches = 1, .min_sample_ns = 1 },
        .{ .warmup_batches = 1, .min_sample_ns = 0 },
    };
    for (configs, [_]usize{ 1, 2, 2 }) |initial, fail_at| {
        var config = initial;
        config.allocator = std.testing.allocator;
        config.batch_repeats = 1;
        state.calls = 0;
        state.fail_at = fail_at;
        try std.testing.expectError(error.WorkloadFailed, runConfigured(std.testing.io, config, state.workload));
        try std.testing.expectEqual(fail_at, state.calls);
    }
}

test "allocation accounting handles growth shrink remap and failure" {
    var storage: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var counter: CountingAllocator = .{ .parent = fixed.allocator() };
    const allocator = counter.allocator();
    var buffer = try allocator.alloc(u8, 32);
    try std.testing.expect(allocator.resize(buffer, 64));
    buffer = buffer.ptr[0..64];
    try std.testing.expect(allocator.resize(buffer, 16));
    buffer = buffer.ptr[0..16];
    buffer = allocator.remap(buffer, 48) orelse return error.UnexpectedRemapFailure;
    try std.testing.expectEqual(@as(usize, 96), counter.bytes);
    try std.testing.expect(!allocator.resize(buffer, 1024));
    try std.testing.expect(allocator.remap(buffer, 1024) == null);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1024));
    allocator.free(buffer);
    try std.testing.expectEqual(@as(usize, 96), counter.bytes);
}
