const std = @import("std");
const Entity = @import("entity.zig").Entity;

pub const component = struct {
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
};

pub const resource = struct {
    pub fn Added(comptime T: type) type {
        return struct {
            const Resource = T;
        };
    }

    pub fn Destroying(comptime T: type) type {
        return struct {
            const Resource = T;
        };
    }
};

test "component events produce a distinct type per component type" {
    const A = struct { value: u8 };
    const B = struct { value: u16 };

    try std.testing.expect(component.Added(A) != component.Added(B));
    try std.testing.expect(component.Destroying(A) != component.Destroying(B));
    try std.testing.expect(component.Added(A) != component.Destroying(A));
}

test "component events only store the entity" {
    try std.testing.expectEqual(@sizeOf(Entity), @sizeOf(component.Added(struct { value: u8 })));
}

test "resource events produce a distinct type per resource type" {
    const A = struct { value: u8 };
    const B = struct { value: u16 };

    try std.testing.expect(resource.Added(A) != resource.Added(B));
    try std.testing.expect(resource.Destroying(A) != resource.Destroying(B));
    try std.testing.expect(resource.Added(A) != resource.Destroying(A));
}

test "resource events do not collide with component events for the same type" {
    const Config = struct { value: u8 };

    const hash = @import("hash.zig").hash;

    try std.testing.expect(hash(resource.Added(Config)) != hash(component.Added(Config)));
    try std.testing.expect(hash(resource.Destroying(Config)) != hash(component.Destroying(Config)));
}

test "resource events carry no payload" {
    try std.testing.expectEqual(0, @sizeOf(resource.Added(struct { value: u8 })));
}
