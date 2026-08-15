const std = @import("std");

const Entity = @import("entity.zig").Entity;
const Error = @import("error.zig").Error;
const World = @import("world.zig").World;
const ComponentPointers = @import("component.zig").ComponentPointers;
const componentId = @import("component.zig").componentId;

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
            component_indices: [components.len]?usize = undefined,

            pub fn next(self: *Iterator) ?ComponentPointers(components) {
                while (self.archetype_cursor < self.world.archetypes.items.len) {
                    const archetype = &self.world.archetypes.items[self.archetype_cursor];

                    if (self.entity_cursor == 0) {
                        archetype.getComponentIndices(&component_ids, &self.component_indices) catch {
                            self.archetype_cursor += 1;
                            continue;
                        };
                    }

                    if (self.entity_cursor >= archetype.entity_count) {
                        self.archetype_cursor += 1;
                        self.entity_cursor = 0;
                        continue;
                    }

                    var bytes: [components.len][]u8 = undefined;
                    archetype.getComponentsByIndices(self.entity_cursor, &self.component_indices, &bytes);

                    var result: ComponentPointers(components) = undefined;
                    inline for (components, 0..) |Component, index| {
                        if (comptime @sizeOf(Component) == 0) {
                            result[index] = &struct {
                                var instance: Component = .{};
                            }.instance;
                        } else {
                            result[index] = @ptrCast(@alignCast(bytes[index].ptr));
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
            return self.world.getEntity(entity, components);
        }
    };
}

test "fromWorld: binds the world the query reads from" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{Position{ .x = 1, .y = 2 }});

    const query = Query(&.{Position}).fromWorld(allocator, &world);
    const position = query.first() orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(&world, query.world);
    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position[0].*);
}

test "iterator: yields every entity across all matching archetypes" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{Position{ .x = 1, .y = 1 }});
    _ = world.addEntity(allocator, .{ Position{ .x = 2, .y = 2 }, Velocity{ .dx = 2, .dy = 2 } });

    var count: usize = 0;
    var sum_x: f32 = 0;

    const query = world.query(&.{Position});
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

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{Position{ .x = 1, .y = 1 }});
    _ = world.addEntity(allocator, .{ Position{ .x = 2, .y = 2 }, Anchor{ .value = 7 } });

    var lone: [1]?usize = undefined;
    var shared: [1]?usize = undefined;
    try world.archetypes.items[0].getComponentIndices(&.{componentId(Position)}, &lone);
    try world.archetypes.items[1].getComponentIndices(&.{componentId(Position)}, &shared);
    try std.testing.expect(lone[0].? != shared[0].?);

    var seen: [2]f32 = @splat(0);
    var count: usize = 0;

    var it = world.query(&.{Position}).iterator();
    while (it.next()) |result| : (count += 1) seen[count] = result[0].x;

    try std.testing.expectEqual(2, count);
    try std.testing.expectEqual(@as(f32, 1), seen[0]);
    try std.testing.expectEqual(@as(f32, 2), seen[1]);
}

test "iterator: returns null when no archetype matches" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{Velocity{ .dx = 1, .dy = 1 }});

    const query = world.query(&.{Position});
    var it = query.iterator();
    try std.testing.expectEqual(null, it.next());
}

test "iterator: skips archetypes without the requested components" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{Velocity{ .dx = 1, .dy = 1 }});
    _ = world.addEntity(allocator, .{Position{ .x = 5, .y = 5 }});

    var count: usize = 0;
    const query = world.query(&.{Position});
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

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{Position{ .x = 1, .y = 1 }});
    _ = world.addEntity(allocator, .{Position{ .x = 2, .y = 2 }});

    const query = world.query(&.{Position});

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

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{Position{ .x = 3, .y = 3 }});

    const query = world.query(&.{Position});

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

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } });

    var forward = world.query(&.{ Position, Velocity }).iterator();
    const position, const velocity = forward.next().?;

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position.*);
    try std.testing.expectEqual(Velocity{ .dx = 3, .dy = 4 }, velocity.*);

    var reverse = world.query(&.{ Velocity, Position }).iterator();
    const reversed_velocity, const reversed_position = reverse.next().?;

    try std.testing.expectEqual(Velocity{ .dx = 3, .dy = 4 }, reversed_velocity.*);
    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, reversed_position.*);
}

test "iterator: filters on a marker without yielding storage" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{ Player{}, Position{ .x = 1, .y = 2 } });
    _ = world.addEntity(allocator, .{Position{ .x = 3, .y = 4 }});

    var it = world.query(&.{ Player, Position }).iterator();
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

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{ Player{}, Position{ .x = 1, .y = 2 } });
    _ = world.addEntity(allocator, .{Position{ .x = 3, .y = 4 }});

    var it = world.query(&.{Position}).iterator();
    var matched: usize = 0;
    while (it.next()) |_| matched += 1;

    try std.testing.expectEqual(2, matched);
}

test "iterator: yields an entity built only from markers" {
    const allocator = std.testing.allocator;

    const Player = struct {};

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{Player{}});

    try std.testing.expect(world.query(&.{Player}).first() != null);
}

test "first: returns the first matching entity's components" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{Position{ .x = 1, .y = 2 }});
    _ = world.addEntity(allocator, .{Position{ .x = 3, .y = 4 }});

    const position = world.query(&.{Position}).first() orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position[0].*);
}

test "first: writes through to the stored components" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = world.addEntity(allocator, .{Position{ .x = 1, .y = 0 }});

    const position = world.query(&.{Position}).first() orelse
        return error.TestUnexpectedResult;
    position[0].x += 10;

    const reread = try world.getEntity(entity, &.{Position});
    try std.testing.expectEqual(@as(f32, 11), reread[0].x);
}

test "first: returns null when nothing matches" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{Position{ .x = 1, .y = 2 }});

    try std.testing.expectEqual(null, world.query(&.{Velocity}).first());
}

test "first: skips despawned entities" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = world.addEntity(allocator, .{Position{ .x = 1, .y = 2 }});
    _ = world.addEntity(allocator, .{Position{ .x = 3, .y = 4 }});
    world.removeEntity(allocator, entity);

    const position = world.query(&.{Position}).first() orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(Position{ .x = 3, .y = 4 }, position[0].*);
}

test "get: returns pointers to the components the query declares" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = world.addEntity(
        allocator,
        .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } },
    );

    const position, const velocity = try world.query(&.{ Position, Velocity }).get(entity);

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position.*);
    try std.testing.expectEqual(Velocity{ .dx = 3, .dy = 4 }, velocity.*);
}

test "get: writes through to the stored components" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = world.addEntity(allocator, .{Position{ .x = 1, .y = 0 }});

    const position = try world.query(&.{Position}).get(entity);
    position[0].x += 10;

    const reread = try world.getEntity(entity, &.{Position});
    try std.testing.expectEqual(@as(f32, 11), reread[0].x);
}

test "get: returns UnknownComponent for an entity outside the query" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = world.addEntity(allocator, .{Position{ .x = 1, .y = 2 }});

    try std.testing.expectError(
        Error.UnknownComponent,
        world.query(&.{Velocity}).get(entity),
    );
}

test "get: returns InvalidEntity for an out of range entity id" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    try std.testing.expectError(
        Error.InvalidEntity,
        world.query(&.{Position}).get(.{ .id = 999, .generation = 0 }),
    );
}

test "get: returns InvalidEntity for a despawned entity" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = world.addEntity(allocator, .{Position{ .x = 1, .y = 2 }});
    world.removeEntity(allocator, entity);

    try std.testing.expectError(
        Error.InvalidEntity,
        world.query(&.{Position}).get(entity),
    );
}
