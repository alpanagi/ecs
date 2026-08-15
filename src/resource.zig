const std = @import("std");

const World = @import("world.zig").World;
const panic = @import("util.zig").panic;

pub fn Resource(comptime T: type) type {
    return struct {
        value: *T,

        pub fn fromWorld(_: std.mem.Allocator, world: *World) @This() {
            const value = world.getResource(T) orelse panic(
                "system requires resource {s} but it is not registered",
                .{@typeName(T)},
            );
            return .{ .value = value };
        }
    };
}

test "fromWorld: points at the resource stored in the world" {
    const allocator = std.testing.allocator;

    const ClearColor = struct { r: f32, g: f32, b: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    world.addResource(allocator, ClearColor, .{ .r = 0.5, .g = 0, .b = 0 });

    const color = Resource(ClearColor).fromWorld(allocator, &world);

    try std.testing.expectEqual(@as(f32, 0.5), color.value.r);
    try std.testing.expectEqual(world.getResource(ClearColor).?, color.value);
}

test "fromWorld: writes through to the stored resource" {
    const allocator = std.testing.allocator;

    const Counter = struct { hits: u32 };

    var world = World.init();
    defer world.deinit(allocator);

    world.addResource(allocator, Counter, .{ .hits = 0 });

    const counter = Resource(Counter).fromWorld(allocator, &world);
    counter.value.hits += 1;

    try std.testing.expectEqual(1, world.getResource(Counter).?.hits);
}

test "fromWorld: sees a resource replaced after it was read" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    world.addResource(allocator, Config, .{ .scale = 1 });
    world.addResource(allocator, Config, .{ .scale = 2 });

    const config = Resource(Config).fromWorld(allocator, &world);

    try std.testing.expectEqual(@as(f32, 2), config.value.scale);
}
