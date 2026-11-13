const std = @import("std");
const lzbench = @import("lzbench");

// Basic example: benchmark repeated work in batches, after warmup.
fn workload(allocator: std.mem.Allocator, operations: usize) !void {
    for (0..operations) |_| {
        const buf = try allocator.alloc(u8, 4096);
        @memset(buf, 0xAB);
        std.mem.doNotOptimizeAway(buf);
        allocator.free(buf);
    }
}

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").mode == .debug) {
        std.debug.print("Debug build: use zig build bench -Doptimize=ReleaseFast for performance measurements.\n\n", .{});
    }
    const result = try lzbench.runConfigured(init.io, .{
        .warmup_batches = 5,
        .batch_size = 100,
        .sample_count = 30,
        .rounds = 3,
        .batch_repeats = 10,
    }, workload);
    result.print("alloc + memset + free 4KB");
}
