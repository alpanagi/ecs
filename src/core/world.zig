const std = @import("std");

const Archetype = @import("archetype.zig").Archetype;
const Entities = @import("../params/entities.zig").Entities;
const Observers = @import("../params/observers.zig").Observers;
const OneShots = @import("../params/one_shots.zig").OneShots;
const OneShotsPlugin = @import("../plugins/one_shots.zig").OneShotsPlugin;
const PluginsState = @import("plugins.zig").PluginsState;
const Resources = @import("../params/resources.zig").Resources;
const Systems = @import("../params/systems.zig").Systems;

const baseline_groups = [_][]const u8{ "pre_update", "update", "post_update" };

pub const World = struct {
    archetypes: std.ArrayList(Archetype),

    entity_descriptors: std.ArrayList(EntityDescriptor),
    entity_free_list: std.ArrayList(u32),

    systems: Systems.State,
    observers: Observers.State,
    plugins: PluginsState,
    resources: Resources.State,
    one_shots: OneShots.State,
    entities: Entities.State,

    pub fn init(allocator: std.mem.Allocator) World {
        var world: World = .{
            .archetypes = .empty,
            .entity_descriptors = .empty,
            .entity_free_list = .empty,
            .systems = Systems.State.init(),
            .observers = Observers.State.init(),
            .plugins = PluginsState.init(),
            .resources = Resources.State.init(),
            .one_shots = OneShots.State.init(),
            .entities = Entities.State.init(),
        };

        for (baseline_groups) |name| world.systems.declareGroup(allocator, name);

        world.addOwnedPlugin(allocator, OneShotsPlugin{});

        return world;
    }

    pub fn deinit(self: *World, allocator: std.mem.Allocator) void {
        self.plugins.deinit(allocator);
        self.resources.deinit(allocator);
        self.systems.deinit(allocator);
        self.observers.deinit(allocator);
        self.one_shots.deinit(allocator);
        self.entities.deinit(allocator);

        for (self.archetypes.items) |*archetype| archetype.deinit(allocator);

        self.archetypes.deinit(allocator);
        self.entity_descriptors.deinit(allocator);
        self.entity_free_list.deinit(allocator);
    }

    pub fn addOwnedPlugin(self: *World, allocator: std.mem.Allocator, plugin: anytype) void {
        self.plugins.addPlugin(allocator, self, plugin);
    }

    pub fn runSystems(self: *World, allocator: std.mem.Allocator) void {
        self.systems.flushPending(allocator);
        self.observers.flushPending(allocator);
        self.resources.flushPending(allocator, self);
        self.entities.flushPending(allocator, self);

        for (self.systems.groups.items) |group| {
            for (group.systems.items) |entry| entry.run(allocator, self);
            self.resources.flushPending(allocator, self);
            self.entities.flushPending(allocator, self);
        }
    }
};

const EntityDescriptor = struct {
    generation: u32,
    archetype: ?u32,
    row: u32,
};

test "init: returns an empty world holding the baseline schedule" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    try std.testing.expectEqual(0, world.entity_descriptors.items.len);
    try std.testing.expectEqual(0, world.archetypes.items.len);
    try std.testing.expectEqual(0, world.entity_free_list.items.len);

    try std.testing.expectEqual(baseline_groups.len, world.systems.groups.items.len);
    for (baseline_groups, world.systems.groups.items) |name, group| {
        try std.testing.expectEqualStrings(name, group.name);
    }
}

test "deinit: is safe on a freshly initialized world" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    world.deinit(allocator);
}

test "deinit: deinits every archetype it owns" {
    const ComponentDescriptor = @import("component.zig").ComponentDescriptor;

    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init(allocator);
    try world.archetypes.append(allocator, Archetype.init(allocator, &.{ComponentDescriptor.from(Value)}, .{}));
    world.deinit(allocator);
}

test "addOwnedPlugin: runs the plugin's build" {
    const allocator = std.testing.allocator;

    const TestState = struct {
        var built: bool = false;
    };

    const Plugin = struct {
        pub fn build(_: *@This()) void {
            TestState.built = true;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.addOwnedPlugin(allocator, Plugin{});

    try std.testing.expect(TestState.built);
}

test "runSystems: runs a one shot system exactly once" {
    const allocator = std.testing.allocator;

    const TestState = struct {
        var calls: usize = 0;
    };

    const system = struct {
        fn call(_: std.mem.Allocator) void {
            TestState.calls += 1;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    OneShots.fromWorld(allocator, &world).add(allocator, system, null);
    world.runSystems(allocator);
    world.runSystems(allocator);

    try std.testing.expectEqual(1, TestState.calls);
}

test "runSystems: flushes commands queued by a system after each group" {
    const test_allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const system = struct {
        fn call(entities: Entities, allocator: std.mem.Allocator) void {
            entities.spawnOwned(allocator, .{Position{ .x = 1, .y = 2 }});
        }
    }.call;

    var world = World.init(test_allocator);
    defer world.deinit(test_allocator);

    Systems.fromWorld(test_allocator, &world).add(test_allocator, "update", system, null);
    world.runSystems(test_allocator);

    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(1, world.archetypes.items[0].entity_count);
}
