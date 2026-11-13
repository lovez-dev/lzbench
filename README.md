# lzbench

Simple microbenchmarking for Zig, with warmup, automatic batching, and allocation tracking. Tested with Zig 0.17.1.

## Installation

Add lzbench as a dependency in your `build.zig.zon`:

```sh
zig fetch --save "git+https://github.com/lovez-dev/lzbench#main"
```

The `main` branch is tested with Zig 0.17.1.

In your `build.zig`, add the lzbench module as a dependency to your program:

```zig
const lzbench = b.dependency("lzbench", .{
    .target = target,
    .optimize = optimize,
});

// The executable from your call to b.addExecutable(...).
exe.root_module.addImport("lzbench", lzbench.module("lzbench"));
```

This makes `@import("lzbench")` available to your source files. The dependency does not add build steps to your project. Define a step for your own benchmark executable in `build.zig`:

```zig
const run_bench = b.addRunArtifact(exe);
b.step("bench", "Run the benchmark").dependOn(&run_bench.step);
```

You can then run it with:

```sh
zig build bench -Doptimize=ReleaseFast
```

The library is a single file. You can also copy [src/lzbench.zig](src/lzbench.zig) into your project and use `@import("lzbench.zig")`.

## Usage

```zig
const std = @import("std");
const lzbench = @import("lzbench");

pub fn main(init: std.process.Init) !void {
    const result = try lzbench.runConfigured(init.io, .{
        .batch_size = 100,
        .batch_repeats = 10,
        .sample_count = 30,
        .rounds = 3,
    }, allocAndFill);
    result.print("alloc + memset + free 4KB");
}

fn allocAndFill(allocator: std.mem.Allocator, operations: usize) !void {
    for (0..operations) |_| {
        const buffer = try allocator.alloc(u8, 4096);
        @memset(buffer, 0xAB);
        std.mem.doNotOptimizeAway(buffer);
        allocator.free(buffer);
    }
}
```

When working from a checkout of lzbench, run the included example with:

```sh
zig build bench -Doptimize=ReleaseFast
```

Example output (timings will vary):

```text
alloc + memset + free 4KB
  2835.150ns/op sample mean; 2835.150ns/op overall across 360000 operations
  requested bytes/op: not measured (enable count_allocations)
  batch-average samples: 90; median: 2828.025ns/op; p95: 2927.100ns/op; range: 2753.375-2986.250ns/op; stddev: 41.857ns
```

The workload receives an allocator and the number of operations to perform. Complete exactly that many operations: the runner uses this count to calculate ns/op. Any setup and cleanup inside the workload are timed too.

For computation benchmarks, use runtime inputs and pass results to `std.mem.doNotOptimizeAway`. This helps prevent unused work from being removed, but does not prevent constant folding or loop hoisting.

## Configuration

`runConfigured(io, config, workload)` warms up the workload, calibrates the number of calls per sample, and collects results over several rounds. All fields in `Config` are optional:

- `warmup_batches = 5` - workload calls before calibration in each round.
- `batch_size = 1000` - operations per workload call.
- `batch_repeats = 10` - starting number of calls per sample.
- `sample_count = 30` - measured samples per round.
- `min_sample_ns = 10_000_000` - calibration target, in nanoseconds.
- `rounds = 5` - rounds to collect in the same process.
- `allocator = null` - uses `std.heap.page_allocator` unless you provide another allocator.
- `count_allocations = false` - whether to track requested allocation bytes.

Calibration doubles the number of calls until it reaches the duration target, then uses that count for every sample in the round. Each sample reads the monotonic clock once before and once after the work. Warmup and calibration are excluded from the results. Set `min_sample_ns = 0` to skip calibration and use exactly `batch_repeats` calls per sample.

The duration target is not a timeout. Actual sample durations can vary, and the runner cannot interrupt a workload. Rounds do not reset workload state or allocators; manage memory and arena resets yourself.

Batch size, repeats, sample count, and rounds must be positive. The total number of samples cannot exceed 10,000.

To track allocations, enable `count_allocations`. Bytes requested through the supplied allocator are counted, including successful growth. Shrinking and freeing do not subtract bytes. This measures cumulative requests, not peak memory usage. Tracking adds overhead to timed work and does not support concurrent allocation calls.

## Result

`runConfigured` returns a `Result`. Every sample is a batch's elapsed time divided by its operation count. Percentiles and ranges describe these batch averages, **not individual-operation tail latency**.

### Fields

- `total_ns` - total measured time, in nanoseconds.
- `operations` - total measured operation count.
- `allocation_bytes` - cumulative bytes requested during measured work.
- `allocations_measured` - whether allocation tracking was enabled.
- `sample_count` - number of retained samples across all rounds.
- `min_ns`, `max_ns` - smallest and largest sample, in ns/op.
- `worst_ns` - same as `max_ns`.

### Methods

- `print(name)` - prints timings and allocation statistics to stderr.
- `samples()` - returns the sorted ns/op samples, including fractional values.
- `mean()` - arithmetic mean of the samples.
- `overallMean()` - `total_ns / operations`, weighted by operation count.
- `median()` - median of the samples.
- `percentile(95)` - nearest-rank percentile; accepts a comptime value from 0 to 100.
- `stdDev()` - sample standard deviation.
- `coefficientOfVariation()` - sample standard deviation divided by the sample mean.

Different rounds may calibrate to different operation counts, so `mean()` and `overallMean()` can differ. Fractional ns/op values do not imply sub-nanosecond clock resolution.

## Testing

```sh
zig build test
zig build test -Doptimize=ReleaseFast
```

Use an optimized build, increase `batch_size` for short operations, and repeat measurements. Check the median, mean, and variation together before drawing conclusions from small differences.

## License

[MIT](LICENSE)
