const std = @import("std");
const ecs_function_protocol = @import("protocols/ecs_function.zig");

const Observers = @import("../modules/observers/module.zig").Observers;
const Resources = @import("../modules/resources/module.zig").Resources;
const Systems = @import("../modules/systems/module.zig").Systems;
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

pub fn createSystemThunk(system: anytype) Thunk {
    const SystemType = @TypeOf(system);

    if (comptime !ecs_function_protocol.validate(SystemType, .{
        .reject = &.{ Observers, Resources, Systems },
    }))
        @compileError("Does not implement System protocol: " ++ @typeName(SystemType));

    return struct {
        pub fn function(allocator: std.mem.Allocator, world: *World) void {
            runSystem(allocator, world, system);
        }
    }.function;
}

pub const Thunk = *const fn (std.mem.Allocator, *World) void;

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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    runSystem(allocator, &world, system);

    try std.testing.expectEqual(1, TestState.parameter_from_world_calls);
    try std.testing.expectEqual(1, TestState.system_calls);
}

test "createSystemThunk: creates a thunk that calls the passed system" {
    const allocator = std.testing.allocator;

    const TestState = struct {
        var system_calls: u32 = 0;
    };

    const system = struct {
        pub fn function() void {
            TestState.system_calls += 1;
        }
    }.function;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const thunk = createSystemThunk(system);
    thunk(allocator, &world);

    try std.testing.expectEqual(1, TestState.system_calls);
}
