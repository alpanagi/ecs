const std = @import("std");

const ecs = @import("ecs");

const World = ecs.World;
const Entity = ecs.Entity;
const Query = ecs.Query;
const Entities = ecs.Entities;
const Resources = ecs.Resources;
const Systems = ecs.Systems;
const Observers = ecs.Observers;
const OneShots = ecs.OneShots;
const Resource = ecs.Resource;
const Event = ecs.Event;
const EventId = ecs.EventId;
const Error = ecs.Error;
const componentId = ecs.componentId;
const component_events = ecs.events.component;
const resource_events = ecs.events.resource;
const ComponentAdded = ecs.events.ComponentAdded;
const ComponentDestroying = ecs.events.ComponentDestroying;
const ResourceAdded = ecs.events.ResourceAdded;
const ResourceDestroying = ecs.events.ResourceDestroying;

test "integration: a system can take a query as a parameter" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const State = struct {
        var sum: f32 = 0;
    };
    State.sum = 0;

    const system = struct {
        fn call(query: Query(&.{Position})) void {
            var it = query.iterator();
            while (it.next()) |row| State.sum += row[0].x;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.addOwnedEntity(allocator, .{Position{ .x = 1, .y = 0 }});
    _ = world.addOwnedEntity(allocator, .{Position{ .x = 2, .y = 0 }});

    Systems.fromWorld(allocator, &world).add(allocator, "update", system, null);
    world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 3), State.sum);
}

test "integration: a system can mix queries with other parameters in any order" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const State = struct {
        var positions: usize = 0;
        var velocities: usize = 0;
        var saw_entities: bool = false;
    };
    State.positions = 0;
    State.velocities = 0;
    State.saw_entities = false;

    const system = struct {
        fn call(
            velocities: Query(&.{Velocity}),
            entities: Entities,
            _: std.mem.Allocator,
            positions: Query(&.{Position}),
        ) void {
            State.saw_entities = @TypeOf(entities) == Entities;

            var v = velocities.iterator();
            while (v.next()) |_| State.velocities += 1;

            var p = positions.iterator();
            while (p.next()) |_| State.positions += 1;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.addOwnedEntity(allocator, .{Position{ .x = 1, .y = 1 }});
    _ = world.addOwnedEntity(allocator, .{ Position{ .x = 2, .y = 2 }, Velocity{ .dx = 1, .dy = 1 } });

    Systems.fromWorld(allocator, &world).add(allocator, "update", system, null);
    world.runSystems(allocator);

    try std.testing.expectEqual(2, State.positions);
    try std.testing.expectEqual(1, State.velocities);
    try std.testing.expect(State.saw_entities);
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

    const entity = world.addOwnedEntity(allocator, .{Position{ .x = 1, .y = 0 }});

    Systems.fromWorld(allocator, &world).add(allocator, "update", system, null);
    world.runSystems(allocator);

    const position = try world.getEntity(entity, &.{Position});
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

    world.addOwnedResource(allocator, Gravity, .{ .value = 2 });
    const entity = world.addOwnedEntity(allocator, .{Position{ .x = 0, .y = 10 }});
    Systems.fromWorld(allocator, &world).add(allocator, "update", system, null);

    world.runSystems(allocator);

    const position = try world.getEntity(entity, &.{Position});
    try std.testing.expectEqual(@as(f32, 8), position[0].y);
}

test "integration: a system follows an Entity stored in a component" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Target = struct { entity: Entity };

    const State = struct {
        var target_x: f32 = 0;
    };
    State.target_x = 0;

    const system = struct {
        fn call(targets: Query(&.{Target}), positions: Query(&.{Position})) void {
            var it = targets.iterator();
            while (it.next()) |row| {
                const position = positions.get(row[0].entity) catch continue;
                position[0].x += 1;
                State.target_x = position[0].x;
            }
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const target = world.addOwnedEntity(allocator, .{Position{ .x = 5, .y = 0 }});
    _ = world.addOwnedEntity(allocator, .{Target{ .entity = target }});

    Systems.fromWorld(allocator, &world).add(allocator, "update", system, null);
    world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 6), State.target_x);
    const position = try world.getEntity(target, &.{Position});
    try std.testing.expectEqual(@as(f32, 6), position[0].x);
}
