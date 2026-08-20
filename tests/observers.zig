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

test "integration: an observer registering observers for its own event does not disturb the running dispatch" {
    const allocator = std.testing.allocator;

    const observer_count = 16;

    const Damage = struct { amount: u32 };

    const State = struct {
        var registered: bool = false;
        var registrar_calls: usize = 0;
        var bystander_calls: usize = 0;
        var added_calls: usize = 0;
    };
    State.registered = false;
    State.registrar_calls = 0;
    State.bystander_calls = 0;
    State.added_calls = 0;

    const Handlers = struct {
        fn added(_: Event(Damage)) void {
            State.added_calls += 1;
        }

        fn registrar(observers: Observers, _: Event(Damage)) void {
            State.registrar_calls += 1;
            if (State.registered) return;
            State.registered = true;
            for (0..observer_count) |_| observers.addObserver(allocator, EventId.from(Damage), added, null);
        }

        fn bystander(_: Event(Damage)) void {
            State.bystander_calls += 1;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Observers.fromWorld(allocator, &world).addObserver(allocator, EventId.from(Damage), Handlers.registrar, null);
    Observers.fromWorld(allocator, &world).addObserver(allocator, EventId.from(Damage), Handlers.bystander, null);

    world.runSystems(allocator);

    world.dispatchOwnedEvent(allocator, Damage{ .amount = 1 });
    try std.testing.expectEqual(1, State.registrar_calls);
    try std.testing.expectEqual(1, State.bystander_calls);
    try std.testing.expectEqual(0, State.added_calls);

    world.runSystems(allocator);

    world.dispatchOwnedEvent(allocator, Damage{ .amount = 1 });
    try std.testing.expectEqual(2, State.registrar_calls);
    try std.testing.expectEqual(2, State.bystander_calls);
    try std.testing.expectEqual(observer_count, State.added_calls);
}

test "integration: an observer reached through Observers.dispatchOwnedEvent can queue deferred work" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Spawned = struct { x: f32 };

    const State = struct {
        var entities_at_trigger: usize = 0;
    };
    State.entities_at_trigger = 0;

    const onSpawned = struct {
        fn call(entities: Entities, event: Event(Spawned)) void {
            entities.spawnOwned(allocator, .{Position{ .x = event.value.x, .y = 0 }});
        }
    }.call;
    const system = struct {
        fn call(observers: Observers, positions: Query(&.{Position})) void {
            observers.dispatchOwnedEvent(allocator, Spawned{ .x = 5 });
            var it = positions.iterator();
            while (it.next()) |_| State.entities_at_trigger += 1;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Observers.fromWorld(allocator, &world).addObserver(allocator, EventId.from(Spawned), onSpawned, null);
    Systems.fromWorld(allocator, &world).addSystem(allocator, "update", system, null);

    world.runSystems(allocator);

    try std.testing.expectEqual(0, State.entities_at_trigger);
    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(1, world.archetypes.items[0].entity_count);
}

test "integration: an observer reached through Observers.dispatchOwnedEvent can register another observer" {
    const allocator = std.testing.allocator;

    const Damage = struct { amount: u32 };

    const State = struct {
        var registered: bool = false;
        var registrar_calls: usize = 0;
        var added_calls: usize = 0;
    };
    State.registered = false;
    State.registrar_calls = 0;
    State.added_calls = 0;

    const Handlers = struct {
        fn added(_: Event(Damage)) void {
            State.added_calls += 1;
        }

        fn registrar(observers: Observers, _: Event(Damage)) void {
            State.registrar_calls += 1;
            if (State.registered) return;
            State.registered = true;
            for (0..16) |_| observers.addObserver(allocator, EventId.from(Damage), added, null);
        }
    };
    const system = struct {
        fn call(observers: Observers) void {
            observers.dispatchOwnedEvent(allocator, Damage{ .amount = 1 });
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Observers.fromWorld(allocator, &world).addObserver(allocator, EventId.from(Damage), Handlers.registrar, null);
    Systems.fromWorld(allocator, &world).addSystem(allocator, "update", system, null);

    world.runSystems(allocator);
    try std.testing.expectEqual(1, State.registrar_calls);
    try std.testing.expectEqual(0, State.added_calls);

    world.runSystems(allocator);
    try std.testing.expectEqual(2, State.registrar_calls);
    try std.testing.expectEqual(16, State.added_calls);
}

test "integration: a spawn through Entities triggers Added at the flush" {
    const Position = struct { x: f32, y: f32 };

    const State = struct {
        var added_entity: ?Entity = null;
    };
    const onPositionAdded = struct {
        fn call(event: Event(ComponentAdded)) void {
            State.added_entity = event.value.entity;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    Observers.fromWorld(std.testing.allocator, &world).addObserver(std.testing.allocator, component_events.added(Position), onPositionAdded, null);
    Entities.fromWorld(std.testing.allocator, &world).spawnOwned(std.testing.allocator, .{Position{ .x = 1, .y = 2 }});
    try std.testing.expectEqual(null, State.added_entity);

    world.runSystems(std.testing.allocator);

    try std.testing.expect(State.added_entity != null);
}
