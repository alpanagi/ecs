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

test "integration: a one-shot system registered through OneShots runs on the next frame" {
    const allocator = std.testing.allocator;

    const State = struct {
        var first_calls: usize = 0;
        var second_calls: usize = 0;
    };
    State.first_calls = 0;
    State.second_calls = 0;

    const Fixture = struct {
        fn second() void {
            State.second_calls += 1;
        }

        fn first(one_shots: OneShots) void {
            State.first_calls += 1;
            one_shots.addSystem(allocator, second, null);
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    OneShots.fromWorld(allocator, &world).addSystem(allocator, Fixture.first, null);

    world.runSystems(allocator);
    try std.testing.expectEqual(1, State.first_calls);
    try std.testing.expectEqual(0, State.second_calls);

    world.runSystems(allocator);
    try std.testing.expectEqual(1, State.first_calls);
    try std.testing.expectEqual(1, State.second_calls);

    world.runSystems(allocator);
    try std.testing.expectEqual(1, State.first_calls);
    try std.testing.expectEqual(1, State.second_calls);
}

test "integration: a one-shot system sees resources its plugin's build created through Resources" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const State = struct {
        var seen: ?f32 = null;
    };
    State.seen = null;

    const Plugin = struct {
        pub fn build(_: *@This(), one_shots: OneShots, resources: Resources, inner: std.mem.Allocator) void {
            resources.addOwned(inner, Config, .{ .scale = 2 });
            one_shots.addSystem(inner, startup, null);
        }

        fn startup(config: Resource(Config)) void {
            State.seen = config.value.scale;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.addOwnedPlugin(allocator, Plugin{});
    world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 2), State.seen.?);
}

test "integration: a one-shot system sees resources another plugin's build created" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const State = struct {
        var seen: ?f32 = null;
    };
    State.seen = null;

    const Provider = struct {
        pub fn build(_: *@This(), resources: Resources, inner: std.mem.Allocator) void {
            resources.addOwned(inner, Config, .{ .scale = 3 });
        }
    };
    const Consumer = struct {
        pub fn build(_: *@This(), one_shots: OneShots, inner: std.mem.Allocator) void {
            one_shots.addSystem(inner, startup, null);
        }

        fn startup(config: Resource(Config)) void {
            State.seen = config.value.scale;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.addOwnedPlugin(allocator, Consumer{});
    world.addOwnedPlugin(allocator, Provider{});

    world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 3), State.seen.?);
}

test "integration: a one-shot system sees entities its plugin's build spawned through Entities" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const State = struct {
        var seen: usize = 0;
    };
    State.seen = 0;

    const Plugin = struct {
        pub fn build(_: *@This(), entities: Entities, one_shots: OneShots, inner: std.mem.Allocator) void {
            entities.spawnOwned(inner, .{Position{ .x = 1, .y = 1 }});
            one_shots.addSystem(inner, startup, null);
        }

        fn startup(positions: Query(&.{Position})) void {
            var it = positions.iterator();
            while (it.next()) |_| State.seen += 1;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.addOwnedPlugin(allocator, Plugin{});
    world.runSystems(allocator);

    try std.testing.expectEqual(1, State.seen);
}
