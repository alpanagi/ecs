const std = @import("std");
const Entity = @import("entity.zig").Entity;

pub fn Created(comptime T: type) type {
    return struct {
        entity: Entity,
        const Component = T;
    };
}

pub fn Destroyed(comptime T: type) type {
    return struct {
        entity: Entity,
        const Component = T;
    };
}

test "Created produces a distinct type per component type" {
    const A = struct { value: u8 };
    const B = struct { value: u16 };

    try std.testing.expect(Created(A) != Created(B));
    try std.testing.expect(Destroyed(A) != Destroyed(B));
    try std.testing.expect(Created(A) != Destroyed(A));
}

test "Created and Destroyed only store the entity" {
    try std.testing.expectEqual(@sizeOf(Entity), @sizeOf(Created(struct { value: u8 })));
}