const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule(
        "blight",
        .{ .source_file = .{ .path = "blight.zig" },}
    );

    const exe = b.addExecutable(.{
        .name = "test",
        .root_source_file = .{ .path = "test.zig" },
        .target = target,
        .optimize = optimize
    });

    b.installArtifact(exe);

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/image/image.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    // test comment

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}
