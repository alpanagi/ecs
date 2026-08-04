const std = @import("std");

const Archetype = @import("archetype.zig").Archetype;
const Entity = @import("entity.zig").Entity;
const hash = @import("hash.zig").hash;
const hashBytes = @import("hash.zig").hashBytes;
const sortMultiple = @import("sort.zig").sortMultiple;
const panic = @import("util.zig").panic;
const EntityComponents = @import("util.zig").EntityComponents;
const PluginRegistry = @import("plugin_registry.zig").PluginRegistry;
const SystemRegistry = @import("system_registry.zig").SystemRegistry;
const SystemEntry = @import("system_registry.zig").SystemEntry;
const ResourceRegistry = @import("resource_registry.zig").ResourceRegistry;
const CommandQueue = @import("command_queue.zig").CommandQueue;
const SpawnFunctions = @import("command_queue.zig").SpawnFunctions;

pub const World = struct {
    archetypes: std.ArrayList(Archetype),

    entity_generations: std.ArrayList(u32),
    entity_archetypes: std.ArrayList(?u32),
    entity_archetype_slots: std.ArrayList(u32),

    entity_free_list: std.ArrayList(u32),

    system_registry: SystemRegistry,
    plugin_registry: PluginRegistry,
    resource_registry: ResourceRegistry,
    command_queue: CommandQueue,

    pub fn init() World {
        return .{
            .entity_generations = .empty,
            .archetypes = .empty,
            .entity_archetypes = .empty,
            .entity_archetype_slots = .empty,
            .entity_free_list = .empty,
            .system_registry = SystemRegistry.init(),
            .plugin_registry = PluginRegistry.init(),
            .resource_registry = ResourceRegistry.init(),
            .command_queue = CommandQueue.init(),
        };
    }

    pub fn deinit(self: *World, allocator: std.mem.Allocator) void {
        for (self.archetypes.items) |*archetype| archetype.deinit(allocator);

        self.entity_generations.deinit(allocator);
        self.archetypes.deinit(allocator);
        self.entity_archetypes.deinit(allocator);
        self.entity_archetype_slots.deinit(allocator);
        self.entity_free_list.deinit(allocator);
        self.system_registry.deinit(allocator);
        self.plugin_registry.deinit(allocator);
        self.resource_registry.deinit(allocator);
        self.command_queue.deinit(allocator);
    }

    fn addEntity(self: *World, allocator: std.mem.Allocator, components: anytype) !Entity {
        const fields = std.meta.fields(@TypeOf(components));

        const component_types: [fields.len]type = comptime blk: {
            var types: [fields.len]type = undefined;
            for (fields, 0..) |field, idx| types[idx] = field.type;
            break :blk types;
        };

        const archetype_id = try self.findOrCreateArchetype(allocator, &component_types);
        const slot = try self.allocateEntitySlot(allocator);

        const entity = Entity{
            .id = slot,
            .generation = self.entity_generations.items[slot],
        };

        const archetype_slot = try self.archetypes.items[archetype_id].addEntity(
            allocator,
            entity,
            components,
        );

        self.entity_archetypes.items[slot] = archetype_id;
        self.entity_archetype_slots.items[slot] = archetype_slot;

        return entity;
    }

    fn removeEntity(self: *World, allocator: std.mem.Allocator, entity: Entity) !void {
        if (entity.id >= self.entity_generations.items.len) return;
        if (self.entity_generations.items[entity.id] != entity.generation) return;

        const archetype_id = self.entity_archetypes.items[entity.id].?;
        const archetype_slot = self.entity_archetype_slots.items[entity.id];

        const relocated = self.archetypes.items[archetype_id].removeEntity(archetype_slot, allocator);
        if (relocated) |relocated_entity| {
            self.entity_archetype_slots.items[relocated_entity.entity.id] = relocated_entity.entity_index;
        }

        self.entity_generations.items[entity.id] += 1;
        self.entity_archetypes.items[entity.id] = null;

        try self.entity_free_list.append(allocator, entity.id);
    }

    pub fn query(_: *World, comptime components: []const type) Query(components) {
        return .{};
    }

    pub fn spawn(self: *World, allocator: std.mem.Allocator, components: anytype) !void {
        try self.command_queue.spawn(allocator, components, spawnFunctions(@TypeOf(components)));
    }

    pub fn despawn(self: *World, allocator: std.mem.Allocator, entity: Entity) !void {
        try self.command_queue.despawn(allocator, entity, World.removeEntity);
    }

    pub fn addSystem(
        self: *World,
        allocator: std.mem.Allocator,
        group: []const u8,
        comptime function: anytype,
        plugin: anytype,
    ) !void {
        try self.system_registry.registerSystem(allocator, hashBytes(group), function, plugin);
    }

    pub fn runSystems(self: *World, allocator: std.mem.Allocator) !void {
        self.system_registry.runOneShotSystems(allocator, self);
        try self.command_queue.flush(allocator, self);

        var groups = self.system_registry.groupIterator();
        while (groups.next()) |group| {
            for (group) |entry| entry.run(allocator, self);
            try self.command_queue.flush(allocator, self);
        }
    }

    pub fn addOneShotSystem(
        self: *World,
        allocator: std.mem.Allocator,
        comptime function: anytype,
        plugin: anytype,
    ) !void {
        try self.system_registry.registerOneShotSystem(allocator, function, plugin);
    }

    pub fn addObserver(
        self: *World,
        allocator: std.mem.Allocator,
        comptime function: anytype,
        plugin: anytype,
    ) !void {
        try self.system_registry.registerObserver(allocator, function, plugin);
    }

    pub fn trigger(self: *World, allocator: std.mem.Allocator, event: anytype) void {
        self.system_registry.dispatch(allocator, hash(@TypeOf(event)), self, &event);
    }

    pub fn addPlugin(self: *World, allocator: std.mem.Allocator, comptime T: type) !void {
        try self.plugin_registry.addPlugin(allocator, self, T);
    }

    pub fn addResource(
        self: *World,
        allocator: std.mem.Allocator,
        comptime T: type,
        value: T,
    ) !void {
        try self.resource_registry.addResource(allocator, T, value);
    }

    pub fn getResource(self: *World, comptime T: type) ?*T {
        return self.resource_registry.getResource(T);
    }

    pub fn removeResource(self: *World, allocator: std.mem.Allocator, comptime T: type) void {
        self.resource_registry.removeResource(allocator, T);
    }

    fn findOrCreateArchetype(
        self: *World,
        allocator: std.mem.Allocator,
        comptime components: []const type,
    ) !u32 {
        var ids: [components.len]u64 = undefined;
        inline for (components, 0..) |component, idx| ids[idx] = hash(component);

        const ids_slice: []u64 = &ids;
        sortMultiple(ids_slice, .{});

        for (self.archetypes.items, 0..) |archetype, index| {
            if (std.mem.eql(u64, archetype.component_ids, ids_slice)) return @intCast(index);
        }

        var new_archetype = try Archetype.init(allocator, components, null);
        errdefer new_archetype.deinit(allocator);

        try self.archetypes.append(allocator, new_archetype);

        return @intCast(self.archetypes.items.len - 1);
    }

    fn allocateEntitySlot(self: *World, allocator: std.mem.Allocator) !u32 {
        if (self.entity_free_list.pop()) |index| return index;

        try self.entity_generations.append(allocator, 0);
        errdefer _ = self.entity_generations.pop();

        try self.entity_archetypes.append(allocator, null);
        errdefer _ = self.entity_archetypes.pop();

        try self.entity_archetype_slots.append(allocator, 0);

        return @intCast(self.entity_generations.items.len - 1);
    }
};

fn spawnFunctions(comptime Components: type) SpawnFunctions {
    return .{
        .apply = struct {
            fn call(data: *anyopaque, world: *World, allocator: std.mem.Allocator) !void {
                const typed: *Components = @ptrCast(@alignCast(data));
                _ = try world.addEntity(allocator, typed.*);
            }
        }.call,
        .destroy = struct {
            fn call(data: *anyopaque, allocator: std.mem.Allocator) void {
                const typed: *Components = @ptrCast(@alignCast(data));
                allocator.destroy(typed);
            }
        }.call,
    };
}

pub fn Query(comptime components: []const type) type {
    return struct {
        archetype_cursor: usize = 0,
        entity_cursor: u32 = 0,

        pub fn next(self: *@This(), world: *World) ?EntityComponents(components) {
            while (self.archetype_cursor < world.archetypes.items.len) {
                const archetype = &world.archetypes.items[self.archetype_cursor];

                if (self.entity_cursor == 0 and !archetype.hasComponents(components)) {
                    self.archetype_cursor += 1;
                    continue;
                }

                if (self.entity_cursor >= archetype.entity_count) {
                    self.archetype_cursor += 1;
                    self.entity_cursor = 0;
                    continue;
                }

                const result = archetype.getComponents(self.entity_cursor, components) catch |err| {
                    panic("World.Query.next: unexpected error from getComponents: {}\n", .{err});
                };

                self.entity_cursor += 1;
                return result;
            }

            return null;
        }
    };
}

test "World.init returns an empty world" {
    const world = World.init();

    try std.testing.expectEqual(0, world.entity_generations.items.len);
    try std.testing.expectEqual(0, world.archetypes.items.len);
    try std.testing.expectEqual(0, world.entity_archetypes.items.len);
    try std.testing.expectEqual(0, world.entity_archetype_slots.items.len);
    try std.testing.expectEqual(0, world.entity_free_list.items.len);
}

test "World.deinit is safe to call on a freshly initialized world" {
    const allocator = std.testing.allocator;

    var world = World.init();
    world.deinit(allocator);
}

test "World.deinit deinits every archetype it owns" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();

    try world.archetypes.append(allocator, try Archetype.init(allocator, &.{Value}, null));

    world.deinit(allocator);
}

test "findOrCreateArchetype creates a new archetype for a never-seen component set" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const index = try world.findOrCreateArchetype(allocator, &.{ Position, Velocity });

    try std.testing.expectEqual(0, index);
    try std.testing.expectEqual(1, world.archetypes.items.len);
}

test "findOrCreateArchetype returns the existing archetype for an already-seen component set" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const first_index = try world.findOrCreateArchetype(allocator, &.{ Position, Velocity });
    const second_index = try world.findOrCreateArchetype(allocator, &.{ Velocity, Position });

    try std.testing.expectEqual(first_index, second_index);
    try std.testing.expectEqual(1, world.archetypes.items.len);
}

test "findOrCreateArchetype creates separate archetypes for different component sets" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const first_index = try world.findOrCreateArchetype(allocator, &.{Position});
    const second_index = try world.findOrCreateArchetype(allocator, &.{ Position, Velocity });

    try std.testing.expect(first_index != second_index);
    try std.testing.expectEqual(2, world.archetypes.items.len);
}

test "allocateEntitySlot returns fresh, increasing indices when the free list is empty" {
    const allocator = std.testing.allocator;

    var world = World.init();
    defer world.deinit(allocator);

    const first = try world.allocateEntitySlot(allocator);
    const second = try world.allocateEntitySlot(allocator);

    try std.testing.expectEqual(0, first);
    try std.testing.expectEqual(1, second);
    try std.testing.expectEqual(2, world.entity_generations.items.len);
    try std.testing.expectEqual(2, world.entity_archetypes.items.len);
    try std.testing.expectEqual(2, world.entity_archetype_slots.items.len);
    try std.testing.expectEqual(0, world.entity_generations.items[0]);
    try std.testing.expectEqual(null, world.entity_archetypes.items[0]);
}

test "allocateEntitySlot reuses a recycled index from the free list instead of growing" {
    const allocator = std.testing.allocator;

    var world = World.init();
    defer world.deinit(allocator);

    // Simulate an already-allocated, now-dead slot at index 0.
    try world.entity_generations.append(allocator, 1);
    try world.entity_archetypes.append(allocator, null);
    try world.entity_archetype_slots.append(allocator, 0);
    try world.entity_free_list.append(allocator, 0);

    const index = try world.allocateEntitySlot(allocator);

    try std.testing.expectEqual(0, index);
    try std.testing.expectEqual(1, world.entity_generations.items.len);
}

test "World.addEntity creates an entity in a new archetype" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(
        allocator,
        .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } },
    );

    try std.testing.expectEqual(Entity{ .id = 0, .generation = 0 }, entity);
    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(0, world.entity_archetypes.items[0].?);
    try std.testing.expectEqual(0, world.entity_archetype_slots.items[0]);
}

test "World.addEntity reuses the same archetype for entities with the same component set" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const first = try world.addEntity(
        allocator,
        .{ Position{ .x = 1, .y = 1 }, Velocity{ .dx = 1, .dy = 1 } },
    );
    const second = try world.addEntity(
        allocator,
        .{ Position{ .x = 2, .y = 2 }, Velocity{ .dx = 2, .dy = 2 } },
    );

    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(
        world.entity_archetypes.items[first.id].?,
        world.entity_archetypes.items[second.id].?,
    );
    try std.testing.expectEqual(0, world.entity_archetype_slots.items[first.id]);
    try std.testing.expectEqual(1, world.entity_archetype_slots.items[second.id]);
}

test "World.addEntity stores the entity's actual component values" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(allocator, .{Position{ .x = 5, .y = 6 }});

    const archetype_id = world.entity_archetypes.items[entity.id].?;
    const archetype_slot = world.entity_archetype_slots.items[entity.id];

    const position = try world.archetypes.items[archetype_id].getComponents(archetype_slot, &.{Position});

    try std.testing.expectEqual(Position{ .x = 5, .y = 6 }, position[0].*);
}

test "World.addEntity creates an entity from three component types" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: u32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(allocator, .{
        Position{ .x = 1, .y = 2 },
        Velocity{ .dx = 3, .dy = 4 },
        Health{ .hp = 100 },
    });

    const archetype_id = world.entity_archetypes.items[entity.id].?;
    const archetype_slot = world.entity_archetype_slots.items[entity.id];

    const position, const velocity, const health = try world.archetypes.items[archetype_id].getComponents(
        archetype_slot,
        &.{ Position, Velocity, Health },
    );

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position.*);
    try std.testing.expectEqual(Velocity{ .dx = 3, .dy = 4 }, velocity.*);
    try std.testing.expectEqual(Health{ .hp = 100 }, health.*);
}

test "removeEntity is a no-op for an out-of-range entity index" {
    const allocator = std.testing.allocator;

    var world = World.init();
    defer world.deinit(allocator);

    try world.removeEntity(allocator, .{ .id = 999, .generation = 0 });

    try std.testing.expectEqual(0, world.entity_generations.items.len);
}

test "removeEntity is a no-op for a stale generation" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(allocator, .{Value{ .value = 1 }});

    try world.removeEntity(allocator, entity);
    // entity is now stale (generation bumped); removing it again must be a
    // no-op, not a double-free or a second attempt to relocate anything.
    try world.removeEntity(allocator, entity);

    try std.testing.expectEqual(entity.generation + 1, world.entity_generations.items[entity.id]);
}

test "removeEntity marks the entity's slot as dead and recycles its index" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(allocator, .{Value{ .value = 1 }});

    try world.removeEntity(allocator, entity);

    try std.testing.expectEqual(entity.generation + 1, world.entity_generations.items[entity.id]);
    try std.testing.expectEqual(null, world.entity_archetypes.items[entity.id]);
    try std.testing.expectEqual(1, world.entity_free_list.items.len);
    try std.testing.expectEqual(entity.id, world.entity_free_list.items[0]);
}

test "removeEntity fixes up the relocated entity's archetype slot" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();
    defer world.deinit(allocator);

    const first = try world.addEntity(allocator, .{Value{ .value = 1 }});
    _ = try world.addEntity(allocator, .{Value{ .value = 2 }});
    const third = try world.addEntity(allocator, .{Value{ .value = 3 }});

    try world.removeEntity(allocator, first);

    // third was the last entity in the archetype, so it should have been
    // swapped into first's now-vacated archetype slot.
    try std.testing.expectEqual(0, world.entity_archetype_slots.items[third.id]);
}

test "removeEntity deinits resources owned by the removed entity's components" {
    const allocator = std.testing.allocator;

    const OwningComponent = struct {
        buffer: []u8,

        fn init(alloc: std.mem.Allocator) !@This() {
            return .{ .buffer = try alloc.alloc(u8, 8) };
        }

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            alloc.free(self.buffer);
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    const owning = try OwningComponent.init(allocator);
    const entity = try world.addEntity(allocator, .{owning});

    try world.removeEntity(allocator, entity);
}

test "a recycled slot is reused with a bumped generation after removeEntity" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();
    defer world.deinit(allocator);

    const first = try world.addEntity(allocator, .{Value{ .value = 1 }});
    try world.removeEntity(allocator, first);

    const second = try world.addEntity(allocator, .{Value{ .value = 2 }});

    try std.testing.expectEqual(first.id, second.id);
    try std.testing.expectEqual(first.generation + 1, second.generation);
}

test "query yields components for every entity across all matching archetypes" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = try world.addEntity(allocator, .{Position{ .x = 1, .y = 1 }});
    _ = try world.addEntity(allocator, .{ Position{ .x = 2, .y = 2 }, Velocity{ .dx = 2, .dy = 2 } });

    var count: usize = 0;
    var sum_x: f32 = 0;

    var query = world.query(&.{Position});
    while (query.next(&world)) |result| {
        count += 1;
        sum_x += result[0].x;
    }

    try std.testing.expectEqual(2, count);
    try std.testing.expectEqual(@as(f32, 3), sum_x);
}

test "query returns null immediately when no archetypes match" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = try world.addEntity(allocator, .{Velocity{ .dx = 1, .dy = 1 }});

    var query = world.query(&.{Position});
    try std.testing.expectEqual(null, query.next(&world));
}

test "query skips entities in archetypes that don't have the requested components" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = try world.addEntity(allocator, .{Velocity{ .dx = 1, .dy = 1 }});
    _ = try world.addEntity(allocator, .{Position{ .x = 5, .y = 5 }});

    var count: usize = 0;
    var query = world.query(&.{Position});
    while (query.next(&world)) |result| {
        count += 1;
        try std.testing.expectEqual(@as(f32, 5), result[0].x);
    }

    try std.testing.expectEqual(1, count);
}

test "addSystem then runSystems runs the system" {
    const State = struct {
        var called = false;
    };
    const system = struct {
        fn call(_: *World, _: *const std.mem.Allocator) callconv(.c) void {
            State.called = true;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    try world.addSystem(std.testing.allocator, "physics", system, null);

    try world.runSystems(std.testing.allocator);
    try std.testing.expect(State.called);
}

test "addSystem groups systems by the same group name in call order" {
    const State = struct {
        var calls: [2]u8 = undefined;
        var count: usize = 0;
    };
    const a = struct {
        fn call(_: *World, _: *const std.mem.Allocator) callconv(.c) void {
            State.calls[State.count] = 1;
            State.count += 1;
        }
    }.call;
    const b = struct {
        fn call(_: *World, _: *const std.mem.Allocator) callconv(.c) void {
            State.calls[State.count] = 2;
            State.count += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    try world.addSystem(std.testing.allocator, "physics", a, null);
    try world.addSystem(std.testing.allocator, "physics", b, null);

    try world.runSystems(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &State.calls);
}

test "addPlugin runs the plugin's init immediately" {
    const State = struct {
        var initialized: bool = false;
    };
    const Plugin = struct {
        pub fn init(_: std.mem.Allocator) !@This() {
            State.initialized = true;
            return .{};
        }

        pub fn build(_: *@This(), _: *const std.mem.Allocator, _: *World) !void {}
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    try world.addPlugin(std.testing.allocator, Plugin);

    try std.testing.expect(State.initialized);
}

test "a plugin's build can register systems" {
    const Plugin = struct {
        calls: usize = 0,

        pub fn init(_: std.mem.Allocator) !@This() {
            return .{};
        }

        pub fn build(self: *@This(), allocator: *const std.mem.Allocator, world: *World) !void {
            try world.addSystem(allocator.*, "update", system, self);
        }

        fn system(self: *@This(), _: *const std.mem.Allocator, _: *World) void {
            self.calls += 1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    try world.addPlugin(std.testing.allocator, Plugin);

    try world.runSystems(std.testing.allocator);
    const entry: SystemEntry = world.system_registry.groups.values()[0].items[0];
    const plugin: *Plugin = @ptrCast(@alignCast(entry.plugin_function.plugin));
    try std.testing.expectEqual(1, plugin.calls);
}

test "deinit calls a plugin's deinit" {
    const State = struct {
        var count: usize = 0;
    };
    const Plugin = struct {
        pub fn init(_: std.mem.Allocator) !@This() {
            return .{};
        }

        pub fn build(_: *@This(), _: *const std.mem.Allocator, _: *World) !void {}

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {
            State.count += 1;
        }
    };

    var world = World.init();
    try world.addPlugin(std.testing.allocator, Plugin);
    world.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, State.count);
}

test "plugin systems share state across runs" {
    const Plugin = struct {
        count: usize = 0,

        pub fn init(_: std.mem.Allocator) !@This() {
            return .{};
        }

        pub fn build(self: *@This(), allocator: *const std.mem.Allocator, world: *World) !void {
            try world.addSystem(allocator.*, "update", increment, self);
            try world.addSystem(allocator.*, "observe", increment, self);
        }

        fn increment(self: *@This(), _: *const std.mem.Allocator, _: *World) void {
            self.count += 1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    try world.addPlugin(std.testing.allocator, Plugin);

    try world.runSystems(std.testing.allocator);
    try world.runSystems(std.testing.allocator);

    const first_entry = world.system_registry.groups.values()[0].items[0].plugin_function;
    const plugin: *Plugin = @ptrCast(@alignCast(first_entry.plugin));
    try std.testing.expectEqual(4, plugin.count);
    const second_entry = world.system_registry.groups.values()[1].items[0].plugin_function;
    try std.testing.expectEqual(first_entry.plugin, second_entry.plugin);
}

test "systems registered before a plugin build failure remain valid" {
    const Plugin = struct {
        calls: usize = 0,

        pub fn init(_: std.mem.Allocator) !@This() {
            return .{};
        }

        pub fn build(self: *@This(), allocator: *const std.mem.Allocator, world: *World) !void {
            try world.addSystem(allocator.*, "update", update, self);
            return error.Boom;
        }

        fn update(self: *@This(), _: *const std.mem.Allocator, _: *World) void {
            self.calls += 1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.Boom,
        world.addPlugin(std.testing.allocator, Plugin),
    );
    try world.runSystems(std.testing.allocator);
    const entry = world.system_registry.groups.values()[0].items[0];
    const plugin: *Plugin = @ptrCast(@alignCast(entry.plugin_function.plugin));
    try std.testing.expectEqual(1, plugin.calls);
}

test "World.trigger runs an observer registered through World.addObserver" {
    const Damage = struct { amount: u32 };
    const State = struct {
        var seen: u32 = 0;
    };
    const onDamage = struct {
        fn call(_: *World, _: *const std.mem.Allocator, event: *const Damage) callconv(.c) void {
            State.seen = event.amount;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    try world.addObserver(std.testing.allocator, onDamage, null);
    world.trigger(std.testing.allocator, Damage{ .amount = 7 });

    try std.testing.expectEqual(7, State.seen);
}

test "a plugin's build can register an observer through World.addObserver" {
    const Damage = struct { amount: u32 };
    const Plugin = struct {
        total: u32 = 0,

        pub fn build(self: *@This(), allocator: *const std.mem.Allocator, world: *World) !void {
            try world.addObserver(allocator.*, onDamage, self);
        }

        fn onDamage(self: *@This(), _: *const std.mem.Allocator, _: *World, event: *const Damage) void {
            self.total += event.amount;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    try world.addPlugin(std.testing.allocator, Plugin);
    world.trigger(std.testing.allocator, Damage{ .amount = 5 });

    const entry = world.system_registry.observers.values()[0].items[0];
    const plugin: *Plugin = @ptrCast(@alignCast(entry.plugin_function.plugin));
    try std.testing.expectEqual(5, plugin.total);
}

test "World.runSystems runs a one-shot system registered through World.addOneShotSystem, once" {
    const State = struct {
        var calls: usize = 0;
    };
    const system = struct {
        fn call(_: *World, _: *const std.mem.Allocator) callconv(.c) void {
            State.calls += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    try world.addOneShotSystem(std.testing.allocator, system, null);
    try world.runSystems(std.testing.allocator);
    try world.runSystems(std.testing.allocator);

    try std.testing.expectEqual(1, State.calls);
}

test "a plugin's build can register a one-shot system through World.addOneShotSystem" {
    const Plugin = struct {
        calls: usize = 0,

        pub fn build(self: *@This(), allocator: *const std.mem.Allocator, world: *World) !void {
            try world.addOneShotSystem(allocator.*, tick, self);
        }

        fn tick(self: *@This(), _: *const std.mem.Allocator, _: *World) void {
            self.calls += 1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    try world.addPlugin(std.testing.allocator, Plugin);
    try world.runSystems(std.testing.allocator);

    const plugin: *Plugin = @ptrCast(@alignCast(world.plugin_registry.plugins.items[0].plugin));
    try std.testing.expectEqual(1, plugin.calls);
}

test "World.addResource then World.getResource returns the stored value" {
    const ClearColor = struct { r: f32, g: f32, b: f32 };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    try world.addResource(std.testing.allocator, ClearColor, .{ .r = 0, .g = 1, .b = 0 });

    const color = world.getResource(ClearColor).?;
    try std.testing.expectEqual(ClearColor{ .r = 0, .g = 1, .b = 0 }, color.*);
}

test "World.removeResource removes it and calls its deinit" {
    const State = struct {
        var count: usize = 0;
    };
    const Tracked = struct {
        pub fn deinit(_: *@This()) void {
            State.count += 1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    try world.addResource(std.testing.allocator, Tracked, .{});
    world.removeResource(std.testing.allocator, Tracked);

    try std.testing.expectEqual(1, State.count);
    try std.testing.expectEqual(null, world.getResource(Tracked));
}

test "a plugin's build can register a resource, read later by a system" {
    const ClearColor = struct { r: f32, g: f32, b: f32 };
    const ConfigPlugin = struct {
        pub fn build(_: *@This(), allocator: *const std.mem.Allocator, world: *World) !void {
            try world.addResource(allocator.*, ClearColor, .{ .r = 1, .g = 1, .b = 1 });
            try world.addSystem(allocator.*, "update", fadeToBlack, null);
        }

        fn fadeToBlack(world: *World, _: *const std.mem.Allocator) callconv(.c) void {
            const color = world.getResource(ClearColor).?;
            color.r -= 0.1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    try world.addPlugin(std.testing.allocator, ConfigPlugin);
    try world.runSystems(std.testing.allocator);
    try world.runSystems(std.testing.allocator);

    const color = world.getResource(ClearColor).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), color.r, 0.0001);
}

test "World.spawn defers entity creation until the command queue is flushed" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    try world.spawn(allocator, .{Position{ .x = 1, .y = 2 }});
    try std.testing.expectEqual(0, world.archetypes.items.len);

    try world.command_queue.flush(allocator, &world);

    try std.testing.expectEqual(1, world.archetypes.items.len);
}

test "World.despawn defers entity removal until the command queue is flushed" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(allocator, .{Value{ .value = 1 }});

    try world.despawn(allocator, entity);
    try std.testing.expectEqual(0, world.entity_free_list.items.len);

    try world.command_queue.flush(allocator, &world);

    try std.testing.expectEqual(1, world.entity_free_list.items.len);
}

test "World.runSystems flushes commands queued by a system after each group" {
    const Position = struct { x: f32, y: f32 };

    const system = struct {
        fn call(world: *World, allocator: *const std.mem.Allocator) callconv(.c) void {
            world.spawn(allocator.*, .{Position{ .x = 1, .y = 2 }}) catch unreachable;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    try world.addSystem(std.testing.allocator, "spawn", system, null);
    try world.runSystems(std.testing.allocator);

    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(1, world.archetypes.items[0].entity_count);
}
