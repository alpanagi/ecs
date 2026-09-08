const std = @import("std");

const ResourceId = @import("resource_id.zig").ResourceId;
const World = @import("../../core/world.zig").World;

const panic = @import("../../utils/panic.zig").panic;

pub fn Resource(Type: type) type {
    const type_info = @typeInfo(Type);
    const is_optional = type_info == .optional;
    const ResourceType = if (is_optional) type_info.optional.child else Type;

    return struct {
        value: if (is_optional) ?*ResourceType else *ResourceType,

        pub fn fromWorld(_: std.mem.Allocator, world: *World) @This() {
            const resource_box = world.resources.getPtr(ResourceId.fromType(ResourceType)) orelse {
                if (is_optional) return .{ .value = null };

                panic("Tried to access unknown resource: {s}", .{@typeName(Type)});
            };
            return .{ .value = @ptrCast(@alignCast(resource_box.value)) };
        }
    };
}

test "fromWorld: returns the resource if it exists for a nullable type" {
    const Resources = @import("resources_parameter.zig").Resources;

    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const Type = struct { data: u32 };
    var resource: Type = .{ .data = 12 };

    const resources = Resources.fromWorld(allocator, &world);
    resources.addOwned(allocator, &resource);

    const saved_resource = Resource(?Type).fromWorld(allocator, &world).value;

    try std.testing.expectEqual(Type{ .data = 12 }, saved_resource.?.*);
}

test "fromWorld: returns null if the resource doesn't exist for a nullable type" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const Type = struct { data: u32 };

    const resource = Resource(?Type).fromWorld(allocator, &world).value;

    try std.testing.expectEqual(null, resource);
}
