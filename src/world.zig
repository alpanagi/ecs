const std = @import("std");

const Archetype = @import("archetype.zig").Archetype;
const Entity = @import("entity.zig").Entity;
const hash = @import("hash.zig").hash;
const sortMultiple = @import("sort.zig").sortMultiple;
const panic = @import("util.zig").panic;
const EntityComponents = @import("util.zig").EntityComponents;

pub const World = struct {
    archetypes: std.ArrayList(Archetype),

    entity_generations: std.ArrayList(u32),
    entity_archetypes: std.ArrayList(?u32),
    entity_archetype_slots: std.ArrayList(u32),

    entity_free_list: std.ArrayList(u32),

    pub fn init() World {
        return .{
            .entity_generations = .empty,
            .archetypes = .empty,
            .entity_archetypes = .empty,
            .entity_archetype_slots = .empty,
            .entity_free_list = .empty,
        };
    }

    pub fn deinit(self: *World, allocator: std.mem.Allocator) void {
        for (self.archetypes.items) |*archetype| archetype.deinit(allocator);

        self.entity_generations.deinit(allocator);
        self.archetypes.deinit(allocator);
        self.entity_archetypes.deinit(allocator);
        self.entity_archetype_slots.deinit(allocator);
        self.entity_free_list.deinit(allocator);
    }

    pub fn addEntity(self: *World, allocator: std.mem.Allocator, components: anytype) !Entity {
        const fields = std.meta.fields(@TypeOf(components));

        const component_types: [fields.len]type = comptime blk: {
            var types: [fields.len]type = undefined;
            for (fields, 0..) |field, idx| types[idx] = field.type;
            break :blk types;
        };

        const archetype_id = try self.findOrCreateArchetype(allocator, &component_types);
        const slot = try self.allocateEntitySlot(allocator);

        const entity = Entity{
            .id = slot,
            .generation = self.entity_generations.items[slot],
        };

        const archetype_slot = try self.archetypes.items[archetype_id].addEntity(
            allocator,
            entity,
            components,
        );

        self.entity_archetypes.items[slot] = archetype_id;
        self.entity_archetype_slots.items[slot] = archetype_slot;

        return entity;
    }

    pub fn removeEntity(self: *World, allocator: std.mem.Allocator, entity: Entity) !void {
        if (entity.id >= self.entity_generations.items.len) return;
        if (self.entity_generations.items[entity.id] != entity.generation) return;

        const archetype_id = self.entity_archetypes.items[entity.id].?;
        const archetype_slot = self.entity_archetype_slots.items[entity.id];

        const relocated = self.archetypes.items[archetype_id].removeEntity(archetype_slot, allocator);
        if (relocated) |relocated_entity| {
            self.entity_archetype_slots.items[relocated_entity.entity.id] = relocated_entity.entity_index;
        }

        self.entity_generations.items[entity.id] += 1;
        self.entity_archetypes.items[entity.id] = null;

        try self.entity_free_list.append(allocator, entity.id);
    }

    pub fn query(self: *World, comptime components: []const type) Query(components) {
        return .{ .world = self };
    }

    fn findOrCreateArchetype(
        self: *World,
        allocator: std.mem.Allocator,
        comptime components: []const type,
    ) !u32 {
        var ids: [components.len]u64 = undefined;
        inline for (components, 0..) |component, idx| ids[idx] = hash(component);

        const ids_slice: []u64 = &ids;
        sortMultiple(ids_slice, .{});

        for (self.archetypes.items, 0..) |archetype, index| {
            if (std.mem.eql(u64, archetype.component_ids, ids_slice)) return @intCast(index);
        }

        var new_archetype = try Archetype.init(allocator, components, null);
        errdefer new_archetype.deinit(allocator);

        try self.archetypes.append(allocator, new_archetype);

        return @intCast(self.archetypes.items.len - 1);
    }

    fn allocateEntitySlot(self: *World, allocator: std.mem.Allocator) !u32 {
        if (self.entity_free_list.pop()) |index| return index;

        try self.entity_generations.append(allocator, 0);
        errdefer _ = self.entity_generations.pop();

        try self.entity_archetypes.append(allocator, null);
        errdefer _ = self.entity_archetypes.pop();

        try self.entity_archetype_slots.append(allocator, 0);

        return @intCast(self.entity_generations.items.len - 1);
    }
};

pub fn Query(comptime components: []const type) type {
    return struct {
        world: *World,
        archetype_cursor: usize = 0,
        entity_cursor: u32 = 0,

        pub fn next(self: *@This()) ?EntityComponents(components) {
            while (self.archetype_cursor < self.world.archetypes.items.len) {
                const archetype = &self.world.archetypes.items[self.archetype_cursor];

                if (self.entity_cursor == 0 and !archetype.hasComponents(components)) {
                    self.archetype_cursor += 1;
                    continue;
                }

                if (self.entity_cursor >= archetype.entity_count) {
                    self.archetype_cursor += 1;
                    self.entity_cursor = 0;
                    continue;
                }

                const result = archetype.getComponents(self.entity_cursor, components) catch |err| {
                    panic("World.Query.next: unexpected error from getComponents: {}\n", .{err});
                };

                self.entity_cursor += 1;
                return result;
            }

            return null;
        }
    };
}

test "World.init returns an empty world" {
    const world = World.init();

    try std.testing.expectEqual(0, world.entity_generations.items.len);
    try std.testing.expectEqual(0, world.archetypes.items.len);
    try std.testing.expectEqual(0, world.entity_archetypes.items.len);
    try std.testing.expectEqual(0, world.entity_archetype_slots.items.len);
    try std.testing.expectEqual(0, world.entity_free_list.items.len);
}

test "World.deinit is safe to call on a freshly initialized world" {
    const allocator = std.testing.allocator;

    var world = World.init();
    world.deinit(allocator);
}

test "World.deinit deinits every archetype it owns" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();

    try world.archetypes.append(allocator, try Archetype.init(allocator, &.{Value}, null));

    world.deinit(allocator);
}

test "findOrCreateArchetype creates a new archetype for a never-seen component set" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const index = try world.findOrCreateArchetype(allocator, &.{ Position, Velocity });

    try std.testing.expectEqual(0, index);
    try std.testing.expectEqual(1, world.archetypes.items.len);
}

test "findOrCreateArchetype returns the existing archetype for an already-seen component set" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const first_index = try world.findOrCreateArchetype(allocator, &.{ Position, Velocity });
    const second_index = try world.findOrCreateArchetype(allocator, &.{ Velocity, Position });

    try std.testing.expectEqual(first_index, second_index);
    try std.testing.expectEqual(1, world.archetypes.items.len);
}

test "findOrCreateArchetype creates separate archetypes for different component sets" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const first_index = try world.findOrCreateArchetype(allocator, &.{Position});
    const second_index = try world.findOrCreateArchetype(allocator, &.{ Position, Velocity });

    try std.testing.expect(first_index != second_index);
    try std.testing.expectEqual(2, world.archetypes.items.len);
}

test "allocateEntitySlot returns fresh, increasing indices when the free list is empty" {
    const allocator = std.testing.allocator;

    var world = World.init();
    defer world.deinit(allocator);

    const first = try world.allocateEntitySlot(allocator);
    const second = try world.allocateEntitySlot(allocator);

    try std.testing.expectEqual(0, first);
    try std.testing.expectEqual(1, second);
    try std.testing.expectEqual(2, world.entity_generations.items.len);
    try std.testing.expectEqual(2, world.entity_archetypes.items.len);
    try std.testing.expectEqual(2, world.entity_archetype_slots.items.len);
    try std.testing.expectEqual(0, world.entity_generations.items[0]);
    try std.testing.expectEqual(null, world.entity_archetypes.items[0]);
}

test "allocateEntitySlot reuses a recycled index from the free list instead of growing" {
    const allocator = std.testing.allocator;

    var world = World.init();
    defer world.deinit(allocator);

    // Simulate an already-allocated, now-dead slot at index 0.
    try world.entity_generations.append(allocator, 1);
    try world.entity_archetypes.append(allocator, null);
    try world.entity_archetype_slots.append(allocator, 0);
    try world.entity_free_list.append(allocator, 0);

    const index = try world.allocateEntitySlot(allocator);

    try std.testing.expectEqual(0, index);
    try std.testing.expectEqual(1, world.entity_generations.items.len);
}

test "World.addEntity creates an entity in a new archetype" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(
        allocator,
        .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } },
    );

    try std.testing.expectEqual(Entity{ .id = 0, .generation = 0 }, entity);
    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(0, world.entity_archetypes.items[0].?);
    try std.testing.expectEqual(0, world.entity_archetype_slots.items[0]);
}

test "World.addEntity reuses the same archetype for entities with the same component set" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const first = try world.addEntity(
        allocator,
        .{ Position{ .x = 1, .y = 1 }, Velocity{ .dx = 1, .dy = 1 } },
    );
    const second = try world.addEntity(
        allocator,
        .{ Position{ .x = 2, .y = 2 }, Velocity{ .dx = 2, .dy = 2 } },
    );

    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(
        world.entity_archetypes.items[first.id].?,
        world.entity_archetypes.items[second.id].?,
    );
    try std.testing.expectEqual(0, world.entity_archetype_slots.items[first.id]);
    try std.testing.expectEqual(1, world.entity_archetype_slots.items[second.id]);
}

test "World.addEntity stores the entity's actual component values" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(allocator, .{Position{ .x = 5, .y = 6 }});

    const archetype_id = world.entity_archetypes.items[entity.id].?;
    const archetype_slot = world.entity_archetype_slots.items[entity.id];

    const position = try world.archetypes.items[archetype_id].getComponents(archetype_slot, &.{Position});

    try std.testing.expectEqual(Position{ .x = 5, .y = 6 }, position[0].*);
}

test "World.addEntity creates an entity from three component types" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: u32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(allocator, .{
        Position{ .x = 1, .y = 2 },
        Velocity{ .dx = 3, .dy = 4 },
        Health{ .hp = 100 },
    });

    const archetype_id = world.entity_archetypes.items[entity.id].?;
    const archetype_slot = world.entity_archetype_slots.items[entity.id];

    const position, const velocity, const health = try world.archetypes.items[archetype_id].getComponents(
        archetype_slot,
        &.{ Position, Velocity, Health },
    );

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position.*);
    try std.testing.expectEqual(Velocity{ .dx = 3, .dy = 4 }, velocity.*);
    try std.testing.expectEqual(Health{ .hp = 100 }, health.*);
}

test "removeEntity is a no-op for an out-of-range entity index" {
    const allocator = std.testing.allocator;

    var world = World.init();
    defer world.deinit(allocator);

    try world.removeEntity(allocator, .{ .id = 999, .generation = 0 });

    try std.testing.expectEqual(0, world.entity_generations.items.len);
}

test "removeEntity is a no-op for a stale generation" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(allocator, .{Value{ .value = 1 }});

    try world.removeEntity(allocator, entity);
    // entity is now stale (generation bumped); removing it again must be a
    // no-op, not a double-free or a second attempt to relocate anything.
    try world.removeEntity(allocator, entity);

    try std.testing.expectEqual(entity.generation + 1, world.entity_generations.items[entity.id]);
}

test "removeEntity marks the entity's slot as dead and recycles its index" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(allocator, .{Value{ .value = 1 }});

    try world.removeEntity(allocator, entity);

    try std.testing.expectEqual(entity.generation + 1, world.entity_generations.items[entity.id]);
    try std.testing.expectEqual(null, world.entity_archetypes.items[entity.id]);
    try std.testing.expectEqual(1, world.entity_free_list.items.len);
    try std.testing.expectEqual(entity.id, world.entity_free_list.items[0]);
}

test "removeEntity fixes up the relocated entity's archetype slot" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();
    defer world.deinit(allocator);

    const first = try world.addEntity(allocator, .{Value{ .value = 1 }});
    _ = try world.addEntity(allocator, .{Value{ .value = 2 }});
    const third = try world.addEntity(allocator, .{Value{ .value = 3 }});

    try world.removeEntity(allocator, first);

    // third was the last entity in the archetype, so it should have been
    // swapped into first's now-vacated archetype slot.
    try std.testing.expectEqual(0, world.entity_archetype_slots.items[third.id]);
}

test "removeEntity deinits resources owned by the removed entity's components" {
    const allocator = std.testing.allocator;

    const OwningComponent = struct {
        buffer: []u8,

        fn init(alloc: std.mem.Allocator) !@This() {
            return .{ .buffer = try alloc.alloc(u8, 8) };
        }

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            alloc.free(self.buffer);
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    const owning = try OwningComponent.init(allocator);
    const entity = try world.addEntity(allocator, .{owning});

    try world.removeEntity(allocator, entity);
}

test "a recycled slot is reused with a bumped generation after removeEntity" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();
    defer world.deinit(allocator);

    const first = try world.addEntity(allocator, .{Value{ .value = 1 }});
    try world.removeEntity(allocator, first);

    const second = try world.addEntity(allocator, .{Value{ .value = 2 }});

    try std.testing.expectEqual(first.id, second.id);
    try std.testing.expectEqual(first.generation + 1, second.generation);
}

test "query yields components for every entity across all matching archetypes" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = try world.addEntity(allocator, .{Position{ .x = 1, .y = 1 }});
    _ = try world.addEntity(allocator, .{ Position{ .x = 2, .y = 2 }, Velocity{ .dx = 2, .dy = 2 } });

    var count: usize = 0;
    var sum_x: f32 = 0;

    var query = world.query(&.{Position});
    while (query.next()) |result| {
        count += 1;
        sum_x += result[0].x;
    }

    try std.testing.expectEqual(2, count);
    try std.testing.expectEqual(@as(f32, 3), sum_x);
}

test "query returns null immediately when no archetypes match" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = try world.addEntity(allocator, .{Velocity{ .dx = 1, .dy = 1 }});

    var query = world.query(&.{Position});
    try std.testing.expectEqual(null, query.next());
}

test "query skips entities in archetypes that don't have the requested components" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = try world.addEntity(allocator, .{Velocity{ .dx = 1, .dy = 1 }});
    _ = try world.addEntity(allocator, .{Position{ .x = 5, .y = 5 }});

    var count: usize = 0;
    var query = world.query(&.{Position});
    while (query.next()) |result| {
        count += 1;
        try std.testing.expectEqual(@as(f32, 5), result[0].x);
    }

    try std.testing.expectEqual(1, count);
}
