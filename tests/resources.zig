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

test "integration: a resource removed through Resources stays readable for the rest of the group" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const TestState = struct {
        var seen_after_remove: ?f32 = null;
    };
    TestState.seen_after_remove = null;

    const Fixture = struct {
        fn remover(config: Resource(Config), resources: Resources) void {
            resources.remove(allocator, Config);
            config.value.scale += 1;
        }

        fn reader(config: Resource(Config)) void {
            TestState.seen_after_remove = config.value.scale;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.resources.addOwned(&world, allocator, Config, .{ .scale = 1 });
    Systems.fromWorld(allocator, &world).add(allocator, "update", Fixture.remover, null);
    Systems.fromWorld(allocator, &world).add(allocator, "update", Fixture.reader, null);

    world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 2), TestState.seen_after_remove.?);
    try std.testing.expectEqual(null, world.resources.get(Config));
}

test "integration: a resource added through Resources is visible to the next group" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const TestState = struct {
        var seen: ?f32 = null;
    };
    TestState.seen = null;

    const Fixture = struct {
        fn producer(resources: Resources) void {
            resources.addOwned(allocator, Config, .{ .scale = 3 });
        }

        fn consumer(config: Resource(Config)) void {
            TestState.seen = config.value.scale;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Systems.fromWorld(allocator, &world).add(allocator, "pre_update", Fixture.producer, null);
    Systems.fromWorld(allocator, &world).add(allocator, "update", Fixture.consumer, null);

    world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 3), TestState.seen.?);
}

test "integration: an unflushed addResource value is freed without being applied" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Resources.fromWorld(allocator, &world).addOwned(allocator, Config, .{ .scale = 1 });

    world.entities.deinit(allocator);
    world.entities = Entities.State.init();

    try std.testing.expectEqual(null, world.resources.get(Config));
}

test "integration: a resource Added observer can already read the resource" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const TestState = struct {
        var seen: ?f32 = null;
    };
    TestState.seen = null;

    const onAdded = struct {
        fn call(config: Resource(Config), _: Event(ResourceAdded)) void {
            TestState.seen = config.value.scale;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Observers.fromWorld(allocator, &world).add(allocator, resource_events.added(Config), onAdded, null);
    Resources.fromWorld(allocator, &world).addOwned(allocator, Config, .{ .scale = 3 });

    world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 3), TestState.seen.?);
}

test "integration: a resource added through Resources fires Added at the flush" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const TestState = struct {
        var calls: usize = 0;
    };
    TestState.calls = 0;

    const onAdded = struct {
        fn call(_: Event(ResourceAdded)) void {
            TestState.calls += 1;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Observers.fromWorld(allocator, &world).add(allocator, resource_events.added(Config), onAdded, null);
    Resources.fromWorld(allocator, &world).addOwned(allocator, Config, .{ .scale = 1 });
    try std.testing.expectEqual(0, TestState.calls);

    world.runSystems(allocator);

    try std.testing.expectEqual(1, TestState.calls);
}

test "integration: a resource removed through Resources fires Destroying at the flush" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const TestState = struct {
        var calls: usize = 0;
    };
    TestState.calls = 0;

    const onDestroying = struct {
        fn call(_: Event(ResourceDestroying)) void {
            TestState.calls += 1;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Observers.fromWorld(allocator, &world).add(allocator, resource_events.destroying(Config), onDestroying, null);
    world.resources.addOwned(&world, allocator, Config, .{ .scale = 1 });

    Resources.fromWorld(allocator, &world).remove(allocator, Config);
    try std.testing.expectEqual(0, TestState.calls);

    world.runSystems(allocator);

    try std.testing.expectEqual(1, TestState.calls);
}
