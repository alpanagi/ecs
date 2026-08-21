const std = @import("std");

const ecs = @import("ecs");

const World = ecs.World;
const Entity = ecs.Entity;
const Query = ecs.Query;
const Entities = ecs.Entities;
const Systems = ecs.Systems;
const Resource = ecs.Resource;

test "integration: a system can take a query as a parameter" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const TestState = struct {
        var sum: f32 = 0;
    };
    TestState.sum = 0;

    const system = struct {
        fn call(query: Query(&.{Position})) void {
            var it = query.iterator();
            while (it.next()) |row| TestState.sum += row[0].x;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 0 }});
    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 2, .y = 0 }});

    Systems.fromWorld(allocator, &world).add(allocator, "update", system, null);
    world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 3), TestState.sum);
}

test "integration: a system can mix queries with other parameters in any order" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestState = struct {
        var positions: usize = 0;
        var velocities: usize = 0;
        var saw_entities: bool = false;
    };
    TestState.positions = 0;
    TestState.velocities = 0;
    TestState.saw_entities = false;

    const system = struct {
        fn call(
            velocities: Query(&.{Velocity}),
            entities: Entities,
            _: std.mem.Allocator,
            positions: Query(&.{Position}),
        ) void {
            TestState.saw_entities = @TypeOf(entities) == Entities;

            var v = velocities.iterator();
            while (v.next()) |_| TestState.velocities += 1;

            var p = positions.iterator();
            while (p.next()) |_| TestState.positions += 1;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 1 }});
    _ = world.entities.spawnOwned(&world, allocator, .{ Position{ .x = 2, .y = 2 }, Velocity{ .dx = 1, .dy = 1 } });

    Systems.fromWorld(allocator, &world).add(allocator, "update", system, null);
    world.runSystems(allocator);

    try std.testing.expectEqual(2, TestState.positions);
    try std.testing.expectEqual(1, TestState.velocities);
    try std.testing.expect(TestState.saw_entities);
}

test "integration: a query parameter can mutate the components it yields" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const system = struct {
        fn call(query: Query(&.{Position})) void {
            var it = query.iterator();
            while (it.next()) |row| row[0].x += 10;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 0 }});

    Systems.fromWorld(allocator, &world).add(allocator, "update", system, null);
    world.runSystems(allocator);

    const position = try Query(&.{Position}).fromWorld(allocator, &world).get(entity);
    try std.testing.expectEqual(@as(f32, 11), position[0].x);
}

test "integration: a system can mix resources, queries and the world" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Gravity = struct { value: f32 };

    const system = struct {
        fn call(
            gravity: Resource(Gravity),
            query: Query(&.{Position}),
        ) void {
            var it = query.iterator();
            while (it.next()) |row| row[0].y -= gravity.value.value;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.resources.addOwned(&world, allocator, Gravity, .{ .value = 2 });
    const entity = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 0, .y = 10 }});
    Systems.fromWorld(allocator, &world).add(allocator, "update", system, null);

    world.runSystems(allocator);

    const position = try Query(&.{Position}).fromWorld(allocator, &world).get(entity);
    try std.testing.expectEqual(@as(f32, 8), position[0].y);
}

test "integration: a system follows an Entity stored in a component" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Target = struct { entity: Entity };

    const TestState = struct {
        var target_x: f32 = 0;
    };
    TestState.target_x = 0;

    const system = struct {
        fn call(targets: Query(&.{Target}), positions: Query(&.{Position})) void {
            var it = targets.iterator();
            while (it.next()) |row| {
                const position = positions.get(row[0].entity) catch continue;
                position[0].x += 1;
                TestState.target_x = position[0].x;
            }
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const target = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 5, .y = 0 }});
    _ = world.entities.spawnOwned(&world, allocator, .{Target{ .entity = target }});

    Systems.fromWorld(allocator, &world).add(allocator, "update", system, null);
    world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 6), TestState.target_x);
    const position = try Query(&.{Position}).fromWorld(allocator, &world).get(target);
    try std.testing.expectEqual(@as(f32, 6), position[0].x);
}
