const std = @import("std");

const World = @import("world.zig").World;

pub fn runSystem(allocator: std.mem.Allocator, world: *World, system: anytype) void {
    const SystemType = @TypeOf(system);

    var arguments: std.meta.ArgsTuple(SystemType) = undefined;
    inline for (&arguments) |*argument| {
        const ArgumentType = @TypeOf(argument.*);
        if (ArgumentType == std.mem.Allocator) {
            argument.* = allocator;
            continue;
        }

        argument.* = ArgumentType.fromWorld(allocator, world);
    }

    @call(.auto, system, arguments);
}

test "runSystem: runs valid system with initialized parameters" {
    const TestState = struct {
        var parameter_from_world_calls: u32 = 0;
        var system_calls: u32 = 0;
    };

    const Parameter = struct {
        data: u32,

        pub fn fromWorld(_: std.mem.Allocator, _: *World) @This() {
            TestState.parameter_from_world_calls += 1;

            return .{ .data = 11 };
        }
    };

    const system = struct {
        pub fn function(_: std.mem.Allocator, _: Parameter) void {
            TestState.system_calls += 1;
        }
    }.function;

    const allocator = std.testing.allocator;

    var world = World.init();
    defer world.deinit(allocator);

    runSystem(allocator, &world, system);

    try std.testing.expectEqual(1, TestState.parameter_from_world_calls);
    try std.testing.expectEqual(1, TestState.system_calls);
}
