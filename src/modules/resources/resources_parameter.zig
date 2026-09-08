const std = @import("std");
const mutable_pointer_protocol = @import("../../utils/protocols/mutable_pointer.zig");

const Box = @import("../../utils/box.zig").Box;
const ResourceId = @import("resource_id.zig").ResourceId;
const World = @import("../../core/world.zig").World;

const panic = @import("../../utils/panic.zig").panic;
const panicOom = @import("../../utils/panic.zig").panicOom;

pub const Resources = struct {
    resources: *std.AutoHashMapUnmanaged(ResourceId, Box),

    pub fn fromWorld(_: std.mem.Allocator, world: *World) Resources {
        return Resources{
            .resources = &world.resources,
        };
    }

    pub fn addOwned(self: *const Resources, allocator: std.mem.Allocator, resource: anytype) void {
        const PointerType = @TypeOf(resource);

        if (comptime !mutable_pointer_protocol.validate(PointerType)) @compileError(
            "Resources need to be passed as mutable pointers to Resources.addOwned. Got: " ++
                @typeName(PointerType),
        );

        const ResourceType = @typeInfo(PointerType).pointer.child;
        const resource_id = ResourceId.fromType(ResourceType);

        const gop = self.resources.getOrPut(allocator, resource_id) catch panicOom(@This(), @src());
        if (gop.found_existing) panic(
            "Tried to add the same resource twice: {s}",
            .{@typeName(ResourceType)},
        );

        const resource_dupe = allocator.create(ResourceType) catch panicOom(@This(), @src());
        resource_dupe.* = resource.*;
        const resource_box = Box.fromOwnedPointer(resource_dupe);
        gop.value_ptr.* = resource_box;

        resource.* = undefined;
    }
};

test "addOwned: adds resource to resources" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const parameter = Resources.fromWorld(allocator, &world);

    const Type = struct { data: u32 };
    var resource: Type = .{ .data = 11 };

    parameter.addOwned(allocator, &resource);

    const box = world.resources.get(ResourceId.fromType(Type)).?;
    const saved_resource: *Type = @ptrCast(@alignCast(box.value));

    const expected = Type{ .data = 11 };
    try std.testing.expectEqual(expected, saved_resource.*);
}
