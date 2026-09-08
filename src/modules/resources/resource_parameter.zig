const std = @import("std");

const ResourceId = @import("resource_id.zig").ResourceId;
const World = @import("../../core/world.zig").World;

const panic = @import("../../utils/panic.zig").panic;

pub fn Resource(Type: type) type {
    return struct {
        value: *Type,

        pub fn fromWorld(_: std.mem.Allocator, world: *World) @This() {
            const resource_box = world.resources.getPtr(ResourceId.fromType(Type));
            if (resource_box == null) panic(
                "Tried to access unknown resource: {s}",
                .{@typeName(Type)},
            );

            return .{ .value = @ptrCast(@alignCast(resource_box.?.value)) };
        }
    };
}
