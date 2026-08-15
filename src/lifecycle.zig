const std = @import("std");

const Entity = @import("entity.zig").Entity;
const EventId = @import("event.zig").EventId;
const ComponentDescriptor = @import("component.zig").ComponentDescriptor;
const componentId = @import("component.zig").componentId;
const hash = @import("hash.zig").hash;

pub const ComponentAdded = struct {
    entity: Entity,
    component: u64,
};

pub const ComponentDestroying = struct {
    entity: Entity,
    component: u64,
};

pub const ResourceAdded = struct {};

pub const ResourceDestroying = struct {};

pub const component = struct {
    pub fn added(comptime T: type) EventId {
        return .{ .event = hash(ComponentAdded), .subject = componentId(T) };
    }

    pub fn destroying(comptime T: type) EventId {
        return destroyingById(componentId(T));
    }

    pub fn destroyingById(component_id: u64) EventId {
        return .{ .event = hash(ComponentDestroying), .subject = component_id };
    }
};

pub const resource = struct {
    pub fn added(comptime T: type) EventId {
        return .{ .event = hash(ResourceAdded), .subject = hash(T) };
    }

    pub fn destroying(comptime T: type) EventId {
        return .{ .event = hash(ResourceDestroying), .subject = hash(T) };
    }
};

test "ResourceAdded: carries no payload" {
    try std.testing.expectEqual(0, @sizeOf(ResourceAdded));
    try std.testing.expectEqual(0, @sizeOf(ResourceDestroying));
}

test "component.added: keys the subject on the component descriptor's id" {
    const Position = struct { x: f32, y: f32 };

    try std.testing.expectEqual(
        ComponentDescriptor.from(Position).id,
        component.added(Position).subject,
    );
    try std.testing.expectEqual(
        ComponentDescriptor.from(Position).id,
        component.destroying(Position).subject,
    );
}

test "component.added: shares one event across every component" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    try std.testing.expectEqual(component.added(Position).event, component.added(Velocity).event);
}

test "component.added: distinguishes components by subject" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    try std.testing.expect(component.added(Position).subject != component.added(Velocity).subject);
}

test "component.destroying: does not collide with added for the same component" {
    const Position = struct { x: f32, y: f32 };

    try std.testing.expect(component.added(Position).event != component.destroying(Position).event);
    try std.testing.expectEqual(component.added(Position).subject, component.destroying(Position).subject);
}

test "resource.added: does not collide with a component event for the same type" {
    const Config = struct { value: u8 };

    try std.testing.expect(resource.added(Config).event != component.added(Config).event);
    try std.testing.expect(resource.destroying(Config).event != component.destroying(Config).event);
}

test "resource.added: does not collide with destroying for the same resource" {
    const Config = struct { value: u8 };

    try std.testing.expect(resource.added(Config).event != resource.destroying(Config).event);
    try std.testing.expectEqual(resource.added(Config).subject, resource.destroying(Config).subject);
}
