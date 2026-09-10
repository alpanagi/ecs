const std = @import("std");

const ResourceId = @import("resource_id.zig").ResourceId;
const World = @import("../../core/world.zig").World;

const panic = @import("../../utils/panic.zig").panic;

pub fn Resource(Type: type) type {
    return struct {
        value: *Type,

        pub fn fromWorld(_: std.mem.Allocator, world: *World) @This() {
            const resource_box = world.resources.getPtr(ResourceId.fromType(Type)) orelse {
                panic("Tried to access unknown resource: {s}", .{@typeName(Type)});
            };
            return .{ .value = @ptrCast(@alignCast(resource_box.value)) };
        }
    };
}

test "fromWorld: returns the resource if it exists" {
    const Resources = @import("resources_parameter.zig").Resources;

    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const Type = struct { data: u32 };
    var resource: Type = .{ .data = 12 };

    const resources = Resources.fromWorld(allocator, &world);
    resources.addOwned(allocator, &resource);

    const saved_resource = Resource(Type).fromWorld(allocator, &world).value;

    try std.testing.expectEqual(Type{ .data = 12 }, saved_resource.*);
}
