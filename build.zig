const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module: @import("lzbench")
    const lzbench = b.addModule("lzbench", .{
        .root_source_file = b.path("src/lzbench.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Basic example
    const example = b.addExecutable(.{
        .name = "basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lzbench", .module = lzbench },
            },
        }),
    });
    b.installArtifact(example);

    const tests = b.addTest(.{ .root_module = lzbench });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run library tests").dependOn(&run_tests.step);

    const run_example = b.addRunArtifact(example);

    const run_step = b.step("run-example", "Run the basic example");
    run_step.dependOn(&run_example.step);
    b.step("bench", "Run the basic benchmark").dependOn(&run_example.step);
}
