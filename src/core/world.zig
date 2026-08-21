const std = @import("std");

const Archetype = @import("archetype.zig").Archetype;
const Entities = @import("../params/entities.zig").Entities;
const Observers = @import("../params/observers.zig").Observers;
const Plugins = @import("../params/plugins.zig").Plugins;
const OneShots = @import("../params/one_shots.zig").OneShots;
const OneShotsPlugin = @import("../plugins/one_shots.zig").OneShotsPlugin;
const Resources = @import("../params/resources.zig").Resources;
const Systems = @import("../params/systems.zig").Systems;

const baseline_groups = [_][]const u8{ "pre_update", "update", "post_update" };

pub const World = struct {
    archetypes: std.ArrayList(Archetype),
    entity_descriptors: std.ArrayList(EntityDescriptor),
    entity_free_list: std.ArrayList(u32),

    entities: Entities.State,
    resources: Resources.State,
    systems: Systems.State,
    observers: Observers.State,
    one_shots: OneShots.State,
    plugins: Plugins.State,

    pub fn init(allocator: std.mem.Allocator) World {
        var world: World = .{
            .archetypes = .empty,
            .entity_descriptors = .empty,
            .entity_free_list = .empty,
            .entities = Entities.State.init(),
            .resources = Resources.State.init(),
            .systems = Systems.State.init(),
            .observers = Observers.State.init(),
            .one_shots = OneShots.State.init(),
            .plugins = Plugins.State.init(),
        };

        for (baseline_groups) |name| world.systems.declareGroup(allocator, name);

        world.addOwnedPlugin(allocator, OneShotsPlugin{});

        return world;
    }

    pub fn deinit(self: *World, allocator: std.mem.Allocator) void {
        self.plugins.deinit(allocator);
        self.one_shots.deinit(allocator);
        self.observers.deinit(allocator);
        self.systems.deinit(allocator);
        self.resources.deinit(allocator);
        self.entities.deinit(allocator);

        self.entity_free_list.deinit(allocator);
        self.entity_descriptors.deinit(allocator);
        for (self.archetypes.items) |*archetype| archetype.deinit(allocator);
        self.archetypes.deinit(allocator);
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

test "runSystems: flushes commands queued by a system before the next group runs" {
    const Query = @import("../params/views/query.zig").Query;

    const test_allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const TestState = struct {
        var seen: usize = 0;
    };

    const Fixture = struct {
        fn spawn(entities: Entities, allocator: std.mem.Allocator) void {
            entities.spawnOwned(allocator, .{Position{ .x = 1, .y = 2 }});
        }

        fn observe(positions: Query(&.{Position})) void {
            var it = positions.iterator();
            while (it.next()) |_| TestState.seen += 1;
        }
    };

    var world = World.init(test_allocator);
    defer world.deinit(test_allocator);

    const systems = Systems.fromWorld(test_allocator, &world);
    systems.add(test_allocator, "pre_update", Fixture.spawn, null);
    systems.add(test_allocator, "update", Fixture.observe, null);

    world.runSystems(test_allocator);

    try std.testing.expectEqual(1, TestState.seen);
}
