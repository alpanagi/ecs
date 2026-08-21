const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ecs = b.addModule("ecs", .{
        .root_source_file = b.path("src/ecs.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ecs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const integration = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ecs", .module = ecs }},
        }),
    });

    const unit_step = b.step("test:unit", "Run unit tests");
    unit_step.dependOn(&b.addRunArtifact(unit).step);

    const integration_step = b.step("test:integration", "Run integration tests");
    integration_step.dependOn(&b.addRunArtifact(integration).step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(unit_step);
    test_step.dependOn(integration_step);
}
