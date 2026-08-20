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

test "integration: a system registered through Systems into an existing group first runs on the next frame" {
    const allocator = std.testing.allocator;

    const system_count = 32;

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

    const Fixture = struct {
        fn added() void {
            State.added_calls += 1;
        }

        fn registrar(systems: Systems) void {
            State.registrar_calls += 1;
            if (State.registered) return;
            State.registered = true;
            for (0..system_count) |_| systems.addSystem(allocator, "update", added, null);
        }

        fn bystander() void {
            State.bystander_calls += 1;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Systems.fromWorld(allocator, &world).addSystem(allocator, "update", Fixture.registrar, null);
    Systems.fromWorld(allocator, &world).addSystem(allocator, "update", Fixture.bystander, null);

    world.runSystems(allocator);
    try std.testing.expectEqual(1, State.registrar_calls);
    try std.testing.expectEqual(1, State.bystander_calls);
    try std.testing.expectEqual(0, State.added_calls);

    world.runSystems(allocator);
    try std.testing.expectEqual(2, State.registrar_calls);
    try std.testing.expectEqual(2, State.bystander_calls);
    try std.testing.expectEqual(system_count, State.added_calls);
}

test "integration: a system registered through Systems into a new group first runs on the next frame" {
    const allocator = std.testing.allocator;

    const group_count = 32;

    const State = struct {
        var registered: bool = false;
        var added_calls: usize = 0;
    };
    State.registered = false;
    State.added_calls = 0;

    const Fixture = struct {
        fn added() void {
            State.added_calls += 1;
        }

        fn registrar(systems: Systems) void {
            if (State.registered) return;
            State.registered = true;
            for (0..group_count) |index| {
                var buffer: [16]u8 = undefined;
                const group = std.fmt.bufPrint(&buffer, "group{d}", .{index}) catch unreachable;
                systems.declareGroup(allocator, group);
                systems.addSystem(allocator, group, added, null);
            }
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const baseline = world.systems.groups.items.len;
    Systems.fromWorld(allocator, &world).addSystem(allocator, "update", Fixture.registrar, null);

    world.runSystems(allocator);
    try std.testing.expectEqual(baseline, world.systems.groups.items.len);
    try std.testing.expectEqual(0, State.added_calls);

    world.runSystems(allocator);
    try std.testing.expectEqual(baseline + group_count, world.systems.groups.items.len);
    try std.testing.expectEqual(group_count, State.added_calls);
}

test "integration: runs nothing when no system is registered" {
    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    world.runSystems(std.testing.allocator);
}

test "integration: a declared group runs in the position it was placed" {
    const allocator = std.testing.allocator;

    const State = struct {
        var calls: [3]u8 = undefined;
        var count: usize = 0;
    };
    State.count = 0;

    const Order = struct {
        fn pre(_: std.mem.Allocator) void {
            State.calls[State.count] = 1;
            State.count += 1;
        }
        fn physics(_: std.mem.Allocator) void {
            State.calls[State.count] = 2;
            State.count += 1;
        }
        fn update(_: std.mem.Allocator) void {
            State.calls[State.count] = 3;
            State.count += 1;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Systems.fromWorld(allocator, &world).addGroupAfter(allocator, "pre_update", "physics");

    Systems.fromWorld(allocator, &world).addSystem(allocator, "update", Order.update, null);
    Systems.fromWorld(allocator, &world).addSystem(allocator, "physics", Order.physics, null);
    Systems.fromWorld(allocator, &world).addSystem(allocator, "pre_update", Order.pre, null);

    world.runSystems(allocator);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &State.calls);
}
