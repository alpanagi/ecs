const std = @import("std");
const Entity = @import("entity.zig").Entity;

pub fn Added(comptime T: type) type {
    return struct {
        entity: Entity,
        const Component = T;
    };
}

pub fn Destroying(comptime T: type) type {
    return struct {
        entity: Entity,
        const Component = T;
    };
}

test "Added produces a distinct type per component type" {
    const A = struct { value: u8 };
    const B = struct { value: u16 };

    try std.testing.expect(Added(A) != Added(B));
    try std.testing.expect(Destroying(A) != Destroying(B));
    try std.testing.expect(Added(A) != Destroying(A));
}

test "Added and Destroying only store the entity" {
    try std.testing.expectEqual(@sizeOf(Entity), @sizeOf(Added(struct { value: u8 })));
}