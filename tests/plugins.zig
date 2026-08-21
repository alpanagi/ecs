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

test "integration: a plugin system and observer can declare parameters beyond the receiver" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Damage = struct { amount: u32 };

    const Plugin = struct {
        moved: usize = 0,
        damage_seen: u32 = 0,

        pub fn init(_: std.mem.Allocator) @This() {
            return .{};
        }

        pub fn build(self: *@This(), observers: Observers, systems: Systems, inner: std.mem.Allocator) void {
            systems.add(inner, "update", move, self);
            observers.add(inner, EventId.from(Damage), onDamage, self);
        }

        fn move(self: *@This(), query: Query(&.{Position})) void {
            var it = query.iterator();
            while (it.next()) |row| {
                row[0].x += 1;
                self.moved += 1;
            }
        }

        fn onDamage(self: *@This(), event: Event(Damage)) void {
            self.damage_seen += event.value.amount;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.addOwnedEntity(allocator, .{Position{ .x = 0, .y = 0 }});
    _ = world.addOwnedEntity(allocator, .{Position{ .x = 5, .y = 0 }});

    world.addOwnedPlugin(allocator, Plugin{});
    world.runSystems(allocator);
    world.dispatchOwnedEvent(allocator, Damage{ .amount = 7 });

    const plugin = world.plugins.plugins.items[0];
    const typed: *Plugin = @ptrCast(@alignCast(plugin.plugin));

    try std.testing.expectEqual(2, typed.moved);
    try std.testing.expectEqual(7, typed.damage_seen);
}

test "integration: a plugin can still query entities from its deinit" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const WorldRef = struct {
        world: *World,

        pub fn fromWorld(_: std.mem.Allocator, world: *World) @This() {
            return .{ .world = world };
        }
    };

    const State = struct {
        var seen: usize = 0;
    };
    State.seen = 0;

    const Plugin = struct {
        world: *World = undefined,

        pub fn init(_: std.mem.Allocator) @This() {
            return .{};
        }

        pub fn build(self: *@This(), plugin_allocator: std.mem.Allocator, world: WorldRef) void {
            self.world = world.world;
            _ = world.world.addOwnedEntity(plugin_allocator, .{Position{ .x = 1, .y = 1 }});
            _ = world.world.addOwnedEntity(plugin_allocator, .{Position{ .x = 2, .y = 2 }});
        }

        pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
            const query = self.world.query(&.{Position});
            var it = query.iterator();
            while (it.next()) |_| State.seen += 1;
        }
    };

    var world = World.init(allocator);
    world.addOwnedPlugin(allocator, Plugin{});
    world.deinit(allocator);

    try std.testing.expectEqual(2, State.seen);
}

test "integration: a plugin's build can register systems bound to the plugin" {
    const State = struct {
        var seen: usize = 0;
    };
    State.seen = 0;

    const Plugin = struct {
        calls: usize = 0,

        pub fn init(_: std.mem.Allocator) @This() {
            return .{};
        }

        pub fn build(self: *@This(), systems: Systems, allocator: std.mem.Allocator) void {
            systems.add(allocator, "update", system, self);
        }

        fn system(self: *@This(), _: std.mem.Allocator) void {
            self.calls += 1;
            State.seen = self.calls;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    world.addOwnedPlugin(std.testing.allocator, Plugin{});

    world.runSystems(std.testing.allocator);
    world.runSystems(std.testing.allocator);

    try std.testing.expectEqual(2, State.seen);
}

test "integration: deinit calls a plugin's deinit" {
    const State = struct {
        var count: usize = 0;
    };
    const Plugin = struct {
        pub fn init(_: std.mem.Allocator) @This() {
            return .{};
        }

        pub fn build(_: *@This(), _: std.mem.Allocator) void {}

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {
            State.count += 1;
        }
    };

    var world = World.init(std.testing.allocator);
    world.addOwnedPlugin(std.testing.allocator, Plugin{});
    world.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, State.count);
}

test "integration: plugin systems share state across runs" {
    const Plugin = struct {
        count: usize = 0,

        pub fn init(_: std.mem.Allocator) @This() {
            return .{};
        }

        pub fn build(self: *@This(), systems: Systems, allocator: std.mem.Allocator) void {
            systems.add(allocator, "update", increment, self);
            systems.add(allocator, "post_update", increment, self);
        }

        fn increment(self: *@This(), _: std.mem.Allocator) void {
            self.count += 1;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    world.addOwnedPlugin(std.testing.allocator, Plugin{});

    world.runSystems(std.testing.allocator);
    world.runSystems(std.testing.allocator);

    const first_entry = world.systems.findGroup("update").?.systems.items[0].plugin_function;
    const plugin: *Plugin = @ptrCast(@alignCast(first_entry.plugin));
    try std.testing.expectEqual(4, plugin.count);
    const second_entry = world.systems.findGroup("post_update").?.systems.items[0].plugin_function;
    try std.testing.expectEqual(first_entry.plugin, second_entry.plugin);
}

test "integration: a plugin's build registers a one shot system" {
    const Plugin = struct {
        calls: usize = 0,

        pub fn build(self: *@This(), one_shots: OneShots, allocator: std.mem.Allocator) void {
            one_shots.add(allocator, tick, self);
        }

        fn tick(self: *@This(), _: std.mem.Allocator) void {
            self.calls += 1;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    world.addOwnedPlugin(std.testing.allocator, Plugin{});
    world.runSystems(std.testing.allocator);

    const plugin: *Plugin = @ptrCast(@alignCast(world.plugins.plugins.items[0].plugin));
    try std.testing.expectEqual(1, plugin.calls);
}

test "integration: a plugin's build can register a resource, read later by a system" {
    const ClearColor = struct { r: f32, g: f32, b: f32 };
    const ConfigPlugin = struct {
        pub fn build(_: *@This(), systems: Systems, resources: Resources, allocator: std.mem.Allocator) void {
            resources.addOwned(allocator, ClearColor, .{ .r = 1, .g = 1, .b = 1 });
            systems.add(allocator, "update", fadeToBlack, null);
        }

        fn fadeToBlack(color: Resource(ClearColor)) void {
            color.value.r -= 0.1;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    world.addOwnedPlugin(std.testing.allocator, ConfigPlugin{});
    world.runSystems(std.testing.allocator);
    world.runSystems(std.testing.allocator);

    const color = world.getResource(ClearColor).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), color.r, 0.0001);
}

test "integration: a plugin's build can register systems, one-shot systems and observers through their params" {
    const allocator = std.testing.allocator;

    const Damage = struct { amount: u32 };

    const Plugin = struct {
        updates: usize = 0,
        setups: usize = 0,
        damage_seen: u32 = 0,

        pub fn build(
            self: *@This(),
            systems: Systems,
            one_shots: OneShots,
            observers: Observers,
            inner: std.mem.Allocator,
        ) void {
            systems.add(inner, "update", update, self);
            one_shots.add(inner, setup, self);
            observers.add(inner, EventId.from(Damage), onDamage, self);
        }

        fn update(self: *@This()) void {
            self.updates += 1;
        }

        fn setup(self: *@This()) void {
            self.setups += 1;
        }

        fn onDamage(self: *@This(), event: Event(Damage)) void {
            self.damage_seen += event.value.amount;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.addOwnedPlugin(allocator, Plugin{});

    world.runSystems(allocator);
    world.runSystems(allocator);
    world.dispatchOwnedEvent(allocator, Damage{ .amount = 7 });

    const plugin: *Plugin = @ptrCast(@alignCast(world.plugins.plugins.items[0].plugin));
    try std.testing.expectEqual(2, plugin.updates);
    try std.testing.expectEqual(1, plugin.setups);
    try std.testing.expectEqual(7, plugin.damage_seen);
}

test "integration: a plugin system registering a plugin system through Systems binds the same plugin" {
    const allocator = std.testing.allocator;

    const Plugin = struct {
        registered: bool = false,
        registrar_calls: usize = 0,
        added_calls: usize = 0,

        pub fn build(self: *@This(), systems: Systems, inner: std.mem.Allocator) void {
            systems.add(inner, "update", registrar, self);
        }

        fn registrar(self: *@This(), systems: Systems) void {
            self.registrar_calls += 1;
            if (self.registered) return;
            self.registered = true;
            systems.add(allocator, "post_update", added, self);
        }

        fn added(self: *@This()) void {
            self.added_calls += 1;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.addOwnedPlugin(allocator, Plugin{});
    const plugin: *Plugin = @ptrCast(@alignCast(world.plugins.plugins.items[0].plugin));

    world.runSystems(allocator);
    try std.testing.expectEqual(1, plugin.registrar_calls);
    try std.testing.expectEqual(0, plugin.added_calls);

    world.runSystems(allocator);
    try std.testing.expectEqual(2, plugin.registrar_calls);
    try std.testing.expectEqual(1, plugin.added_calls);
}

test "integration: a plugin's build can register a resource through Resources" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const State = struct {
        var seen: f32 = 0;
    };
    State.seen = 0;

    const Plugin = struct {
        pub fn build(_: *@This(), systems: Systems, resources: Resources, inner: std.mem.Allocator) void {
            resources.addOwned(inner, Config, .{ .scale = 4 });
            systems.add(inner, "update", read, null);
        }

        fn read(config: Resource(Config)) void {
            State.seen = config.value.scale;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.addOwnedPlugin(allocator, Plugin{});
    try std.testing.expectEqual(null, world.getResource(Config));

    world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 4), State.seen);
}
