const event_view_protocol = @import("../protocols/event_view.zig");
const parameter_protocol = @import("../protocols/parameter.zig");
const std = @import("std");

const World = @import("../core/world.zig").World;

pub fn resolveParameter(allocator: std.mem.Allocator, world: *World, comptime Parameter: type) Parameter {
    if (Parameter == std.mem.Allocator) return allocator;

    if (comptime !parameter_protocol.validate(Parameter)) @compileError(
        @typeName(Parameter) ++ " does not implement the Parameter protocol",
    );

    return Parameter.fromWorld(allocator, world);
}

pub fn resolveObserverParameter(
    allocator: std.mem.Allocator,
    world: *World,
    comptime Parameter: type,
    payload: *const anyopaque,
) Parameter {
    if (comptime event_view_protocol.validate(Parameter)) return Parameter.fromEvent(payload);

    return resolveParameter(allocator, world, Parameter);
}

test "resolveParameter: returns the allocator for an Allocator parameter" {
    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    const resolved = resolveParameter(std.testing.allocator, &world, std.mem.Allocator);

    try std.testing.expectEqual(std.testing.allocator, resolved);
}

test "resolveParameter: hands the allocator and world to fromWorld" {
    const Parameter = struct {
        allocator: std.mem.Allocator,
        world: *World,

        pub fn fromWorld(allocator: std.mem.Allocator, world: *World) @This() {
            return .{ .allocator = allocator, .world = world };
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    const resolved = resolveParameter(std.testing.allocator, &world, Parameter);

    try std.testing.expectEqual(std.testing.allocator, resolved.allocator);
    try std.testing.expectEqual(&world, resolved.world);
}

test "resolveObserverParameter: hands the payload to fromEvent" {
    const Parameter = struct {
        value: u8,

        pub fn fromEvent(payload: *const anyopaque) @This() {
            const typed: *const u8 = @ptrCast(payload);
            return .{ .value = typed.* };
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    const payload: u8 = 42;

    const resolved = resolveObserverParameter(std.testing.allocator, &world, Parameter, &payload);

    try std.testing.expectEqual(42, resolved.value);
}

test "resolveObserverParameter: falls back to fromWorld when fromEvent is absent" {
    const Parameter = struct {
        world: *World,

        pub fn fromWorld(_: std.mem.Allocator, world: *World) @This() {
            return .{ .world = world };
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    const payload: u8 = 0;

    const resolved = resolveObserverParameter(std.testing.allocator, &world, Parameter, &payload);

    try std.testing.expectEqual(&world, resolved.world);
}

test "resolveObserverParameter: prefers fromEvent over fromWorld" {
    const Parameter = struct {
        source: enum { event, world },

        pub fn fromEvent(_: *const anyopaque) @This() {
            return .{ .source = .event };
        }

        pub fn fromWorld(_: std.mem.Allocator, _: *World) @This() {
            return .{ .source = .world };
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    const payload: u8 = 0;

    const resolved = resolveObserverParameter(std.testing.allocator, &world, Parameter, &payload);

    try std.testing.expectEqual(.event, resolved.source);
}

test "resolveObserverParameter: returns the allocator for an Allocator parameter" {
    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    const payload: u8 = 0;

    const resolved = resolveObserverParameter(std.testing.allocator, &world, std.mem.Allocator, &payload);

    try std.testing.expectEqual(std.testing.allocator, resolved);
}
