const std = @import("std");

const Column = @import("../../core/archetype.zig").Column;
const ComponentPointers = @import("../../core/component.zig").ComponentPointers;
const Entity = @import("../../core/entity.zig").Entity;
const Error = @import("../../error.zig").Error;
const World = @import("../../core/world.zig").World;

const componentId = @import("../../core/component.zig").componentId;

pub fn Query(comptime components: []const type) type {
    return struct {
        world: *World,

        pub fn fromWorld(_: std.mem.Allocator, world: *World) @This() {
            return .{ .world = world };
        }

        pub const Iterator = struct {
            const component_ids = blk: {
                var ids: [components.len]u64 = undefined;
                for (components, 0..) |Component, index| ids[index] = componentId(Component);
                break :blk ids;
            };

            world: *World,
            archetype_cursor: usize = 0,
            entity_cursor: u32 = 0,
            columns: [components.len]Column = undefined,

            pub fn next(self: *Iterator) ?ComponentPointers(components) {
                while (self.archetype_cursor < self.world.archetypes.items.len) {
                    const archetype = &self.world.archetypes.items[self.archetype_cursor];

                    if (self.entity_cursor == 0) {
                        archetype.getComponentColumns(&component_ids, &self.columns) catch {
                            self.archetype_cursor += 1;
                            continue;
                        };
                    }

                    if (self.entity_cursor >= archetype.entity_count) {
                        self.archetype_cursor += 1;
                        self.entity_cursor = 0;
                        continue;
                    }

                    const row: usize = self.entity_cursor;
                    var result: ComponentPointers(components) = undefined;
                    inline for (components, 0..) |Component, index| {
                        if (comptime @sizeOf(Component) == 0) {
                            result[index] = &struct {
                                var instance: Component = .{};
                            }.instance;
                        } else {
                            const column = self.columns[index];
                            result[index] = @ptrCast(@alignCast(column.bytes.ptr + row * column.stride));
                        }
                    }

                    self.entity_cursor += 1;
                    return result;
                }

                return null;
            }
        };

        pub fn iterator(self: @This()) Iterator {
            return .{ .world = self.world };
        }

        pub fn first(self: @This()) ?ComponentPointers(components) {
            var it = self.iterator();
            return it.next();
        }

        pub fn get(self: @This(), entity: Entity) !ComponentPointers(components) {
            return getEntity(self.world, entity, components);
        }
    };
}

fn getEntity(
    world: *World,
    entity: Entity,
    comptime components: []const type,
) !ComponentPointers(components) {
    if (entity.id >= world.entity_descriptors.items.len) return Error.InvalidEntity;

    const descriptor = world.entity_descriptors.items[entity.id];
    if (descriptor.generation != entity.generation) return Error.InvalidEntity;

    const archetype_id = descriptor.archetype orelse return Error.InvalidEntity;

    return world.archetypes.items[archetype_id].getComponents(descriptor.row, components);
}

test "fromWorld: binds the world the query reads from" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 2 }});

    const query = Query(&.{Position}).fromWorld(allocator, &world);
    const position = query.first() orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(&world, query.world);
    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position[0].*);
}

test "iterator: yields every entity across all matching archetypes" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 1 }});
    _ = world.entities.spawnOwned(&world, allocator, .{ Position{ .x = 2, .y = 2 }, Velocity{ .dx = 2, .dy = 2 } });

    var count: usize = 0;
    var sum_x: f32 = 0;

    const query = Query(&.{Position}).fromWorld(allocator, &world);
    var it = query.iterator();
    while (it.next()) |result| {
        count += 1;
        sum_x += result[0].x;
    }

    try std.testing.expectEqual(2, count);
    try std.testing.expectEqual(@as(f32, 3), sum_x);
}

test "iterator: resolves component columns separately for each archetype" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Anchor = struct { value: u64 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 1 }});
    _ = world.entities.spawnOwned(&world, allocator, .{ Position{ .x = 2, .y = 2 }, Anchor{ .value = 7 } });

    var lone: [1]Column = undefined;
    var shared: [1]Column = undefined;
    try world.archetypes.items[0].getComponentColumns(&.{componentId(Position)}, &lone);
    try world.archetypes.items[1].getComponentColumns(&.{componentId(Position)}, &shared);

    const lone_is_first = lone[0].bytes.ptr == world.archetypes.items[0].data[0].ptr;
    const shared_is_first = shared[0].bytes.ptr == world.archetypes.items[1].data[0].ptr;
    try std.testing.expect(lone_is_first != shared_is_first);

    var seen: [2]f32 = @splat(0);
    var count: usize = 0;

    var it = Query(&.{Position}).fromWorld(allocator, &world).iterator();
    while (it.next()) |result| : (count += 1) seen[count] = result[0].x;

    try std.testing.expectEqual(2, count);
    try std.testing.expectEqual(@as(f32, 1), seen[0]);
    try std.testing.expectEqual(@as(f32, 2), seen[1]);
}

test "iterator: returns null when no archetype matches" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{Velocity{ .dx = 1, .dy = 1 }});

    const query = Query(&.{Position}).fromWorld(allocator, &world);
    var it = query.iterator();
    try std.testing.expectEqual(null, it.next());
}

test "iterator: skips archetypes without the requested components" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{Velocity{ .dx = 1, .dy = 1 }});
    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 5, .y = 5 }});

    var count: usize = 0;
    const query = Query(&.{Position}).fromWorld(allocator, &world);
    var it = query.iterator();
    while (it.next()) |result| {
        count += 1;
        try std.testing.expectEqual(@as(f32, 5), result[0].x);
    }

    try std.testing.expectEqual(1, count);
}

test "iterator: is independent of others made from the same query" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 1 }});
    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 2, .y = 2 }});

    const query = Query(&.{Position}).fromWorld(allocator, &world);

    var outer = query.iterator();
    var pairs: usize = 0;
    while (outer.next()) |_| {
        var inner = query.iterator();
        while (inner.next()) |_| pairs += 1;
    }

    try std.testing.expectEqual(4, pairs);
}

test "iterator: can be made again after one is exhausted" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 3, .y = 3 }});

    const query = Query(&.{Position}).fromWorld(allocator, &world);

    var first = query.iterator();
    while (first.next()) |_| {}
    try std.testing.expectEqual(null, first.next());

    var second = query.iterator();
    try std.testing.expect(second.next() != null);
}

test "iterator: yields the components in the order the query declares them" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } });

    var forward = Query(&.{ Position, Velocity }).fromWorld(allocator, &world).iterator();
    const position, const velocity = forward.next().?;

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position.*);
    try std.testing.expectEqual(Velocity{ .dx = 3, .dy = 4 }, velocity.*);

    var reverse = Query(&.{ Velocity, Position }).fromWorld(allocator, &world).iterator();
    const reversed_velocity, const reversed_position = reverse.next().?;

    try std.testing.expectEqual(Velocity{ .dx = 3, .dy = 4 }, reversed_velocity.*);
    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, reversed_position.*);
}

test "iterator: filters on a marker without yielding storage" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{ Player{}, Position{ .x = 1, .y = 2 } });
    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 3, .y = 4 }});

    var it = Query(&.{ Player, Position }).fromWorld(allocator, &world).iterator();
    var matched: usize = 0;
    while (it.next()) |row| {
        const position = row[1];
        try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position.*);
        matched += 1;
    }

    try std.testing.expectEqual(1, matched);
}

test "iterator: matches an entity carrying components beyond the query" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{ Player{}, Position{ .x = 1, .y = 2 } });
    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 3, .y = 4 }});

    var it = Query(&.{Position}).fromWorld(allocator, &world).iterator();
    var matched: usize = 0;
    while (it.next()) |_| matched += 1;

    try std.testing.expectEqual(2, matched);
}

test "iterator: yields an entity built only from markers" {
    const allocator = std.testing.allocator;

    const Player = struct {};

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{Player{}});

    try std.testing.expect(Query(&.{Player}).fromWorld(allocator, &world).first() != null);
}

test "first: returns the first matching entity's components" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 2 }});
    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 3, .y = 4 }});

    const position = Query(&.{Position}).fromWorld(allocator, &world).first() orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position[0].*);
}

test "first: writes through to the stored components" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 0 }});

    const position = Query(&.{Position}).fromWorld(allocator, &world).first() orelse
        return error.TestUnexpectedResult;
    position[0].x += 10;

    const reread = try getEntity(&world, entity, &.{Position});
    try std.testing.expectEqual(@as(f32, 11), reread[0].x);
}

test "first: returns null when nothing matches" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 2 }});

    try std.testing.expectEqual(null, Query(&.{Velocity}).fromWorld(allocator, &world).first());
}

test "first: skips despawned entities" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 2 }});
    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 3, .y = 4 }});
    world.entities.despawn(&world, allocator, entity);

    const position = Query(&.{Position}).fromWorld(allocator, &world).first() orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(Position{ .x = 3, .y = 4 }, position[0].*);
}

test "get: returns pointers to the components the query declares" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.entities.spawnOwned(
        &world,
        allocator,
        .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } },
    );

    const position, const velocity = try Query(&.{ Position, Velocity }).fromWorld(allocator, &world).get(entity);

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position.*);
    try std.testing.expectEqual(Velocity{ .dx = 3, .dy = 4 }, velocity.*);
}

test "get: writes through to the stored components" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 0 }});

    const position = try Query(&.{Position}).fromWorld(allocator, &world).get(entity);
    position[0].x += 10;

    const reread = try getEntity(&world, entity, &.{Position});
    try std.testing.expectEqual(@as(f32, 11), reread[0].x);
}

test "get: returns UnknownComponent for an entity outside the query" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 2 }});

    try std.testing.expectError(
        Error.UnknownComponent,
        Query(&.{Velocity}).fromWorld(allocator, &world).get(entity),
    );
}

test "get: returns InvalidEntity for an out of range entity id" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    try std.testing.expectError(
        Error.InvalidEntity,
        Query(&.{Position}).fromWorld(allocator, &world).get(.{ .id = 999, .generation = 0 }),
    );
}

test "get: returns InvalidEntity for a despawned entity" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 2 }});
    world.entities.despawn(&world, allocator, entity);

    try std.testing.expectError(
        Error.InvalidEntity,
        Query(&.{Position}).fromWorld(allocator, &world).get(entity),
    );
}

test "getEntity: returns pointers to the requested components" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.entities.spawnOwned(
        &world,
        allocator,
        .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } },
    );

    const position, const velocity = try getEntity(&world, entity, &.{ Position, Velocity });

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position.*);
    try std.testing.expectEqual(Velocity{ .dx = 3, .dy = 4 }, velocity.*);
}

test "getEntity: returns InvalidEntity for an out of range entity id" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    try std.testing.expectError(
        Error.InvalidEntity,
        getEntity(&world, .{ .id = 999, .generation = 0 }, &.{}),
    );
}

test "getEntity: returns InvalidEntity for a stale generation" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.entities.spawnOwned(&world, allocator, .{Value{ .value = 1 }});
    world.entities.despawn(&world, allocator, entity);

    try std.testing.expectError(
        Error.InvalidEntity,
        getEntity(&world, entity, &.{Value}),
    );
}

test "getEntity: returns UnknownComponent for a component the entity lacks" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 2 }});

    try std.testing.expectError(
        Error.UnknownComponent,
        getEntity(&world, entity, &.{Velocity}),
    );
}

test "getEntity: returns UnknownComponent for a marker the entity lacks" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 2 }});

    try std.testing.expectError(
        Error.UnknownComponent,
        getEntity(&world, entity, &.{ Player, Position }),
    );
}
