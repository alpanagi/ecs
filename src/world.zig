const std = @import("std");

const Archetype = @import("archetype.zig").Archetype;
const LifecycleFunctions = @import("archetype.zig").LifecycleFunctions;
const Entity = @import("entity.zig").Entity;
const Error = @import("error.zig").Error;
const Added = @import("lifecycle.zig").Added;
const Destroying = @import("lifecycle.zig").Destroying;
const hash = @import("hash.zig").hash;
const hashBytes = @import("hash.zig").hashBytes;
const sortMultiple = @import("sort.zig").sortMultiple;
const panic = @import("util.zig").panic;
const EntityComponents = @import("util.zig").EntityComponents;
const PluginRegistry = @import("plugin_registry.zig").PluginRegistry;
const SystemRegistry = @import("system_registry.zig").SystemRegistry;
const SystemEntry = @import("system_registry.zig").SystemEntry;
const Event = @import("system_registry.zig").Event;
const ResourceRegistry = @import("resource_registry.zig").ResourceRegistry;
const ObserverEntry = @import("system_registry.zig").ObserverEntry;
const buildSystemEntry = @import("system_registry.zig").buildSystemEntry;
const buildObserverEntry = @import("system_registry.zig").buildObserverEntry;
const CommandQueue = @import("command_queue.zig").CommandQueue;
const ValueFunctions = @import("command_queue.zig").ValueFunctions;
const RemoveResourceFunction = @import("command_queue.zig").RemoveResourceFunction;
const RegistrationQueue = @import("registration_queue.zig").RegistrationQueue;

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
    registration_queue: RegistrationQueue,

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
            .registration_queue = RegistrationQueue.init(),
        };
    }

    pub fn deinit(self: *World, allocator: std.mem.Allocator) void {
        self.plugin_registry.deinit(allocator);
        self.resource_registry.deinit(allocator);
        self.system_registry.deinit(allocator);
        self.command_queue.deinit(allocator);
        self.registration_queue.deinit(allocator);

        for (self.archetypes.items) |*archetype| archetype.deinit(allocator);

        self.entity_generations.deinit(allocator);
        self.archetypes.deinit(allocator);
        self.entity_archetypes.deinit(allocator);
        self.entity_archetype_slots.deinit(allocator);
        self.entity_free_list.deinit(allocator);
    }

    pub fn addEntity(self: *World, allocator: std.mem.Allocator, components: anytype) !Entity {
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

        for (self.archetypes.items[archetype_id].component_added) |added| {
            added(self, allocator, entity);
        }

        return entity;
    }

    pub fn removeEntity(self: *World, allocator: std.mem.Allocator, entity: Entity) !void {
        if (entity.id >= self.entity_generations.items.len) return;
        if (self.entity_generations.items[entity.id] != entity.generation) return;

        const archetype_id = self.entity_archetypes.items[entity.id].?;

        for (self.archetypes.items[archetype_id].component_destroying) |destroying| {
            destroying(self, allocator, entity);
        }

        const archetype_slot = self.entity_archetype_slots.items[entity.id];

        const relocated = self.archetypes.items[archetype_id].removeEntity(archetype_slot, allocator);
        if (relocated) |relocated_entity| {
            self.entity_archetype_slots.items[relocated_entity.entity.id] = relocated_entity.entity_index;
        }

        self.entity_generations.items[entity.id] += 1;
        self.entity_archetypes.items[entity.id] = null;

        try self.entity_free_list.append(allocator, entity.id);
    }

    pub fn query(self: *World, comptime components: []const type) Query(components) {
        return .{ .world = self };
    }

    pub fn getEntity(
        self: *World,
        entity: Entity,
        comptime components: []const type,
    ) !EntityComponents(components) {
        if (entity.id >= self.entity_generations.items.len) return Error.InvalidEntity;
        if (self.entity_generations.items[entity.id] != entity.generation) return Error.InvalidEntity;

        const archetype_id = self.entity_archetypes.items[entity.id] orelse return Error.InvalidEntity;
        const archetype_slot = self.entity_archetype_slots.items[entity.id];

        return self.archetypes.items[archetype_id].getComponents(archetype_slot, components);
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

    fn flushSystemRegistrations(self: *World, allocator: std.mem.Allocator) !void {
        try self.registration_queue.flush(allocator, &self.system_registry);
    }

    pub fn runSystems(self: *World, allocator: std.mem.Allocator) !void {
        try self.flushSystemRegistrations(allocator);

        self.system_registry.runOneShotSystems(allocator, self);
        try self.command_queue.flush(allocator, self);

        var groups = self.system_registry.groupIterator();
        while (groups.next()) |group| {
            for (group) |entry| {
                entry.run(allocator, self) catch |err| std.log.err("system failed: {}\n", .{err});
            }
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

        var new_archetype = try Archetype.init(allocator, components, null, lifecycleFunctionsFor);
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

fn spawnFunctions(comptime Components: type) ValueFunctions {
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

fn addResourceFunctions(comptime T: type) ValueFunctions {
    return .{
        .apply = struct {
            fn call(data: *anyopaque, world: *World, allocator: std.mem.Allocator) !void {
                const typed: *T = @ptrCast(@alignCast(data));
                try world.addResource(allocator, T, typed.*);
            }
        }.call,
        .destroy = struct {
            fn call(data: *anyopaque, allocator: std.mem.Allocator) void {
                const typed: *T = @ptrCast(@alignCast(data));
                allocator.destroy(typed);
            }
        }.call,
    };
}

fn removeResourceFunction(comptime T: type) RemoveResourceFunction {
    return struct {
        fn call(world: *World, allocator: std.mem.Allocator) void {
            world.removeResource(allocator, T);
        }
    }.call;
}

fn lifecycleFunctionsFor(comptime component: type) LifecycleFunctions {
    return .{
        .added = struct {
            fn call(world_ptr: *anyopaque, allocator: std.mem.Allocator, entity: Entity) void {
                const world: *World = @ptrCast(@alignCast(world_ptr));
                world.trigger(allocator, Added(component){ .entity = entity });
            }
        }.call,
        .destroying = struct {
            fn call(world_ptr: *anyopaque, allocator: std.mem.Allocator, entity: Entity) void {
                const world: *World = @ptrCast(@alignCast(world_ptr));
                world.trigger(allocator, Destroying(component){ .entity = entity });
            }
        }.call,
    };
}

pub fn Query(comptime components: []const type) type {
    return struct {
        world: *World,

        pub fn fromWorld(_: std.mem.Allocator, world: *World) @This() {
            return .{ .world = world };
        }

        pub const Iterator = struct {
            world: *World,
            archetype_cursor: usize = 0,
            entity_cursor: u32 = 0,

            pub fn next(self: *Iterator) ?EntityComponents(components) {
                while (self.archetype_cursor < self.world.archetypes.items.len) {
                    const archetype = &self.world.archetypes.items[self.archetype_cursor];

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
                        panic("World.Query.Iterator.next: unexpected error from getComponents: {}\n", .{err});
                    };

                    self.entity_cursor += 1;
                    return result;
                }

                return null;
            }
        };

        pub fn iterator(self: @This()) Iterator {
            return .{ .world = self.world };
        }

        pub fn get(self: @This(), entity: Entity) !EntityComponents(components) {
            return self.world.getEntity(entity, components);
        }
    };
}

pub const Commands = struct {
    world: *World,
    allocator: std.mem.Allocator,

    pub fn fromWorld(allocator: std.mem.Allocator, world: *World) Commands {
        return .{ .world = world, .allocator = allocator };
    }

    pub fn spawn(self: Commands, components: anytype) !void {
        try self.world.command_queue.spawn(
            self.allocator,
            components,
            spawnFunctions(@TypeOf(components)),
        );
    }

    pub fn despawn(self: Commands, entity: Entity) !void {
        try self.world.command_queue.despawn(self.allocator, entity, World.removeEntity);
    }

    pub fn trigger(self: Commands, event: anytype) void {
        self.world.trigger(self.allocator, event);
    }

    pub fn addResource(self: Commands, comptime T: type, value: T) !void {
        try self.world.command_queue.addResource(self.allocator, value, addResourceFunctions(T));
    }

    pub fn removeResource(self: Commands, comptime T: type) !void {
        try self.world.command_queue.removeResource(self.allocator, removeResourceFunction(T));
    }

    pub fn addSystem(
        self: Commands,
        group: []const u8,
        comptime function: anytype,
        plugin: anytype,
    ) !void {
        try self.world.registration_queue.addSystem(
            self.allocator,
            hashBytes(group),
            buildSystemEntry(function, plugin),
        );
    }

    pub fn addOneShotSystem(
        self: Commands,
        comptime function: anytype,
        plugin: anytype,
    ) !void {
        try self.world.registration_queue.addOneShotSystem(
            self.allocator,
            buildSystemEntry(function, plugin),
        );
    }

    pub fn addObserver(
        self: Commands,
        comptime function: anytype,
        plugin: anytype,
    ) !void {
        const registration = buildObserverEntry(function, plugin);
        try self.world.registration_queue.addObserver(
            self.allocator,
            registration.event,
            registration.entry,
        );
    }
};

pub fn Resource(comptime T: type) type {
    return struct {
        value: *T,

        pub fn fromWorld(_: std.mem.Allocator, world: *World) @This() {
            const value = world.getResource(T) orelse panic(
                "system requires resource {s} but it is not registered\n",
                .{@typeName(T)},
            );
            return .{ .value = value };
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

    try world.archetypes.append(allocator, try Archetype.init(allocator, &.{Value}, null, lifecycleFunctionsFor));

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

    const query = world.query(&.{Position});
    var it = query.iterator();
    while (it.next()) |result| {
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

    const query = world.query(&.{Position});
    var it = query.iterator();
    try std.testing.expectEqual(null, it.next());
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
    const query = world.query(&.{Position});
    var it = query.iterator();
    while (it.next()) |result| {
        count += 1;
        try std.testing.expectEqual(@as(f32, 5), result[0].x);
    }

    try std.testing.expectEqual(1, count);
}

test "one query spec produces independent iterators" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = try world.addEntity(allocator, .{Position{ .x = 1, .y = 1 }});
    _ = try world.addEntity(allocator, .{Position{ .x = 2, .y = 2 }});

    const query = world.query(&.{Position});

    var outer = query.iterator();
    var pairs: usize = 0;
    while (outer.next()) |_| {
        var inner = query.iterator();
        while (inner.next()) |_| pairs += 1;
    }

    try std.testing.expectEqual(4, pairs);
}

test "a query spec is reusable after its iterator is exhausted" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = try world.addEntity(allocator, .{Position{ .x = 3, .y = 3 }});

    const query = world.query(&.{Position});

    var first = query.iterator();
    while (first.next()) |_| {}
    try std.testing.expectEqual(null, first.next());

    var second = query.iterator();
    try std.testing.expect(second.next() != null);
}

test "a system can take a query as a parameter" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const State = struct {
        var sum: f32 = 0;
    };
    State.sum = 0;

    const system = struct {
        fn call(query: Query(&.{Position})) !void {
            var it = query.iterator();
            while (it.next()) |row| State.sum += row[0].x;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    _ = try world.addEntity(allocator, .{Position{ .x = 1, .y = 0 }});
    _ = try world.addEntity(allocator, .{Position{ .x = 2, .y = 0 }});

    try world.addSystem(allocator, "update", system, null);
    try world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 3), State.sum);
}

test "a system can mix queries with other parameters in any order" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const State = struct {
        var positions: usize = 0;
        var velocities: usize = 0;
        var saw_world: bool = false;
    };
    State.positions = 0;
    State.velocities = 0;
    State.saw_world = false;

    const system = struct {
        fn call(
            velocities: Query(&.{Velocity}),
            world: *World,
            _: std.mem.Allocator,
            positions: Query(&.{Position}),
        ) !void {
            State.saw_world = world.archetypes.items.len > 0;

            var v = velocities.iterator();
            while (v.next()) |_| State.velocities += 1;

            var p = positions.iterator();
            while (p.next()) |_| State.positions += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    _ = try world.addEntity(allocator, .{Position{ .x = 1, .y = 1 }});
    _ = try world.addEntity(allocator, .{ Position{ .x = 2, .y = 2 }, Velocity{ .dx = 1, .dy = 1 } });

    try world.addSystem(allocator, "update", system, null);
    try world.runSystems(allocator);

    try std.testing.expectEqual(2, State.positions);
    try std.testing.expectEqual(1, State.velocities);
    try std.testing.expect(State.saw_world);
}

test "a query parameter can mutate the components it yields" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const system = struct {
        fn call(query: Query(&.{Position})) !void {
            var it = query.iterator();
            while (it.next()) |row| row[0].x += 10;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(allocator, .{Position{ .x = 1, .y = 0 }});

    try world.addSystem(allocator, "update", system, null);
    try world.runSystems(allocator);

    const position = try world.getEntity(entity, &.{Position});
    try std.testing.expectEqual(@as(f32, 11), position[0].x);
}

test "a system can take a resource as a parameter" {
    const allocator = std.testing.allocator;

    const ClearColor = struct { r: f32, g: f32, b: f32 };

    const State = struct {
        var red: f32 = 0;
    };
    State.red = 0;

    const system = struct {
        fn call(color: Resource(ClearColor)) !void {
            State.red = color.value.r;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    try world.addResource(allocator, ClearColor, .{ .r = 0.5, .g = 0, .b = 0 });
    try world.addSystem(allocator, "update", system, null);
    try world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 0.5), State.red);
}

test "a resource parameter writes through to the stored resource" {
    const allocator = std.testing.allocator;

    const Counter = struct { hits: u32 };

    const system = struct {
        fn call(counter: Resource(Counter)) !void {
            counter.value.hits += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    try world.addResource(allocator, Counter, .{ .hits = 0 });
    try world.addSystem(allocator, "update", system, null);

    try world.runSystems(allocator);
    try world.runSystems(allocator);

    try std.testing.expectEqual(2, world.getResource(Counter).?.hits);
}

test "a system can mix resources, queries and the world" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Gravity = struct { value: f32 };

    const system = struct {
        fn call(
            gravity: Resource(Gravity),
            query: Query(&.{Position}),
            _: *World,
        ) !void {
            var it = query.iterator();
            while (it.next()) |row| row[0].y -= gravity.value.value;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    try world.addResource(allocator, Gravity, .{ .value = 2 });
    const entity = try world.addEntity(allocator, .{Position{ .x = 0, .y = 10 }});
    try world.addSystem(allocator, "update", system, null);

    try world.runSystems(allocator);

    const position = try world.getEntity(entity, &.{Position});
    try std.testing.expectEqual(@as(f32, 8), position[0].y);
}

test "a plugin system and observer can declare parameters beyond the receiver" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Damage = struct { amount: u32 };

    const Plugin = struct {
        moved: usize = 0,
        damage_seen: u32 = 0,

        pub fn init(_: std.mem.Allocator) !@This() {
            return .{};
        }

        pub fn build(self: *@This(), plugin_allocator: std.mem.Allocator, world: *World) !void {
            try world.addSystem(plugin_allocator, "update", move, self);
            try world.addObserver(plugin_allocator, onDamage, self);
        }

        fn move(self: *@This(), query: Query(&.{Position})) !void {
            var it = query.iterator();
            while (it.next()) |row| {
                row[0].x += 1;
                self.moved += 1;
            }
        }

        fn onDamage(self: *@This(), event: Event(Damage)) !void {
            self.damage_seen += event.value.amount;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    _ = try world.addEntity(allocator, .{Position{ .x = 0, .y = 0 }});
    _ = try world.addEntity(allocator, .{Position{ .x = 5, .y = 0 }});

    try world.addPlugin(allocator, Plugin);
    try world.runSystems(allocator);
    world.trigger(allocator, Damage{ .amount = 7 });

    const plugin = world.plugin_registry.plugins.items[0];
    const typed: *Plugin = @ptrCast(@alignCast(plugin.plugin));

    try std.testing.expectEqual(2, typed.moved);
    try std.testing.expectEqual(7, typed.damage_seen);
}

test "a plugin can still query entities from its deinit" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const State = struct {
        var seen: usize = 0;
    };
    State.seen = 0;

    const Plugin = struct {
        world: *World = undefined,

        pub fn init(_: std.mem.Allocator) !@This() {
            return .{};
        }

        pub fn build(self: *@This(), plugin_allocator: std.mem.Allocator, world: *World) !void {
            self.world = world;
            _ = try world.addEntity(plugin_allocator, .{Position{ .x = 1, .y = 1 }});
            _ = try world.addEntity(plugin_allocator, .{Position{ .x = 2, .y = 2 }});
        }

        pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
            const query = self.world.query(&.{Position});
            var it = query.iterator();
            while (it.next()) |_| State.seen += 1;
        }
    };

    var world = World.init();
    try world.addPlugin(allocator, Plugin);
    world.deinit(allocator);

    try std.testing.expectEqual(2, State.seen);
}

test "World.getEntity returns pointers to the requested entity's components" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(
        allocator,
        .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } },
    );

    const position, const velocity = try world.getEntity(entity, &.{ Position, Velocity });

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position.*);
    try std.testing.expectEqual(Velocity{ .dx = 3, .dy = 4 }, velocity.*);
}

test "World.getEntity returns Error.InvalidEntity for an out-of-range entity index" {
    const allocator = std.testing.allocator;

    var world = World.init();
    defer world.deinit(allocator);

    try std.testing.expectError(
        Error.InvalidEntity,
        world.getEntity(.{ .id = 999, .generation = 0 }, &.{}),
    );
}

test "World.getEntity returns Error.InvalidEntity for a stale generation" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(allocator, .{Value{ .value = 1 }});
    try world.removeEntity(allocator, entity);

    try std.testing.expectError(
        Error.InvalidEntity,
        world.getEntity(entity, &.{Value}),
    );
}

test "World.getEntity returns Error.UnknownComponent for a component the entity does not have" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(allocator, .{Position{ .x = 1, .y = 2 }});

    try std.testing.expectError(
        Error.UnknownComponent,
        world.getEntity(entity, &.{Velocity}),
    );
}

test "addSystem then runSystems runs the system" {
    const State = struct {
        var called = false;
    };
    const system = struct {
        fn call(_: *World, _: std.mem.Allocator) !void {
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
        fn call(_: *World, _: std.mem.Allocator) !void {
            State.calls[State.count] = 1;
            State.count += 1;
        }
    }.call;
    const b = struct {
        fn call(_: *World, _: std.mem.Allocator) !void {
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

        pub fn build(_: *@This(), _: std.mem.Allocator, _: *World) !void {}
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

        pub fn build(self: *@This(), allocator: std.mem.Allocator, world: *World) !void {
            try world.addSystem(allocator, "update", system, self);
        }

        fn system(self: *@This(), _: std.mem.Allocator, _: *World) !void {
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

        pub fn build(_: *@This(), _: std.mem.Allocator, _: *World) !void {}

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

        pub fn build(self: *@This(), allocator: std.mem.Allocator, world: *World) !void {
            try world.addSystem(allocator, "update", increment, self);
            try world.addSystem(allocator, "observe", increment, self);
        }

        fn increment(self: *@This(), _: std.mem.Allocator, _: *World) !void {
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

        pub fn build(self: *@This(), allocator: std.mem.Allocator, world: *World) !void {
            try world.addSystem(allocator, "update", update, self);
            return error.Boom;
        }

        fn update(self: *@This(), _: std.mem.Allocator, _: *World) !void {
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
        fn call(event: Event(Damage)) !void {
            State.seen = event.value.amount;
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

        pub fn build(self: *@This(), allocator: std.mem.Allocator, world: *World) !void {
            try world.addObserver(allocator, onDamage, self);
        }

        fn onDamage(self: *@This(), event: Event(Damage)) !void {
            self.total += event.value.amount;
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
        fn call(_: *World, _: std.mem.Allocator) !void {
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

        pub fn build(self: *@This(), allocator: std.mem.Allocator, world: *World) !void {
            try world.addOneShotSystem(allocator, tick, self);
        }

        fn tick(self: *@This(), _: std.mem.Allocator, _: *World) !void {
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
        pub fn build(_: *@This(), allocator: std.mem.Allocator, world: *World) !void {
            try world.addResource(allocator, ClearColor, .{ .r = 1, .g = 1, .b = 1 });
            try world.addSystem(allocator, "update", fadeToBlack, null);
        }

        fn fadeToBlack(world: *World, _: std.mem.Allocator) !void {
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

test "Commands.spawn defers entity creation until the command queue is flushed" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const commands = Commands.fromWorld(allocator, &world);

    try commands.spawn(.{Position{ .x = 1, .y = 2 }});
    try std.testing.expectEqual(0, world.archetypes.items.len);

    try world.command_queue.flush(allocator, &world);

    try std.testing.expectEqual(1, world.archetypes.items.len);
}

test "Commands.despawn defers entity removal until the command queue is flushed" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(allocator, .{Value{ .value = 1 }});

    const commands = Commands.fromWorld(allocator, &world);

    try commands.despawn(entity);
    try std.testing.expectEqual(0, world.entity_free_list.items.len);

    try world.command_queue.flush(allocator, &world);

    try std.testing.expectEqual(1, world.entity_free_list.items.len);
}

test "World.addEntity creates the entity immediately" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = try world.addEntity(allocator, .{Position{ .x = 1, .y = 2 }});

    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(1, world.archetypes.items[0].entity_count);
}

test "World.runSystems flushes commands queued by a system after each group" {
    const Position = struct { x: f32, y: f32 };

    const system = struct {
        fn call(commands: Commands) !void {
            try commands.spawn(.{Position{ .x = 1, .y = 2 }});
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    try world.addSystem(std.testing.allocator, "spawn", system, null);
    try world.runSystems(std.testing.allocator);

    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(1, world.archetypes.items[0].entity_count);
}

test "World.addEntity triggers an Added event for each component type" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const State = struct {
        var position_entity: ?Entity = null;
        var velocity_entity: ?Entity = null;
    };
    const onPositionAdded = struct {
        fn call(event: Event(Added(Position))) !void {
            State.position_entity = event.value.entity;
        }
    }.call;
    const onVelocityAdded = struct {
        fn call(event: Event(Added(Velocity))) !void {
            State.velocity_entity = event.value.entity;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    try world.addObserver(allocator, onPositionAdded, null);
    try world.addObserver(allocator, onVelocityAdded, null);

    const entity = try world.addEntity(allocator, .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } });

    try std.testing.expectEqual(entity, State.position_entity);
    try std.testing.expectEqual(entity, State.velocity_entity);
}

test "World.addEntity does not trigger Added for a component type with no observer" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const State = struct {
        var position_entity: ?Entity = null;
    };
    const onPositionAdded = struct {
        fn call(event: Event(Added(Position))) !void {
            State.position_entity = event.value.entity;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    try world.addObserver(allocator, onPositionAdded, null);

    _ = try world.addEntity(allocator, .{Velocity{ .dx = 1, .dy = 1 }});

    try std.testing.expectEqual(null, State.position_entity);
}

test "World.removeEntity triggers a Destroying event for each component type" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const State = struct {
        var destroying_entity: ?Entity = null;
    };
    const onPositionDestroying = struct {
        fn call(event: Event(Destroying(Position))) !void {
            State.destroying_entity = event.value.entity;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    try world.addObserver(allocator, onPositionDestroying, null);

    const entity = try world.addEntity(allocator, .{Position{ .x = 1, .y = 2 }});
    try world.removeEntity(allocator, entity);

    try std.testing.expectEqual(entity, State.destroying_entity);
}

test "World.removeEntity fires Destroying while the component is still readable" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const State = struct {
        var observed: ?Position = null;
    };
    const onPositionDestroying = struct {
        fn call(world: *World, event: Event(Destroying(Position))) !void {
            const components = world.getEntity(event.value.entity, &.{Position}) catch return;
            State.observed = components[0].*;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    try world.addObserver(allocator, onPositionDestroying, null);

    const entity = try world.addEntity(allocator, .{Position{ .x = 1, .y = 2 }});
    try world.removeEntity(allocator, entity);

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, State.observed);
}

test "Commands.spawn triggers Added once the command queue is flushed" {
    const Position = struct { x: f32, y: f32 };

    const State = struct {
        var added_entity: ?Entity = null;
    };
    const onPositionAdded = struct {
        fn call(event: Event(Added(Position))) !void {
            State.added_entity = event.value.entity;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    try world.addObserver(std.testing.allocator, onPositionAdded, null);
    try Commands.fromWorld(std.testing.allocator, &world).spawn(.{Position{ .x = 1, .y = 2 }});
    try std.testing.expectEqual(null, State.added_entity);

    try world.runSystems(std.testing.allocator);

    try std.testing.expect(State.added_entity != null);
}

test "a system registered through Commands into an existing group first runs on the next frame" {
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

    const Systems = struct {
        fn added() void {
            State.added_calls += 1;
        }

        fn registrar(commands: Commands) !void {
            State.registrar_calls += 1;
            if (State.registered) return;
            State.registered = true;
            for (0..system_count) |_| try commands.addSystem("update", added, null);
        }

        fn bystander() void {
            State.bystander_calls += 1;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    try world.addSystem(allocator, "update", Systems.registrar, null);
    try world.addSystem(allocator, "update", Systems.bystander, null);

    try world.runSystems(allocator);
    try std.testing.expectEqual(1, State.registrar_calls);
    try std.testing.expectEqual(1, State.bystander_calls);
    try std.testing.expectEqual(0, State.added_calls);

    try world.runSystems(allocator);
    try std.testing.expectEqual(2, State.registrar_calls);
    try std.testing.expectEqual(2, State.bystander_calls);
    try std.testing.expectEqual(system_count, State.added_calls);
}

test "a system registered through Commands into a new group first runs on the next frame" {
    const allocator = std.testing.allocator;

    const group_count = 32;

    const State = struct {
        var registered: bool = false;
        var added_calls: usize = 0;
    };
    State.registered = false;
    State.added_calls = 0;

    const Systems = struct {
        fn added() void {
            State.added_calls += 1;
        }

        fn registrar(commands: Commands) !void {
            if (State.registered) return;
            State.registered = true;
            for (0..group_count) |index| {
                var buffer: [16]u8 = undefined;
                const group = try std.fmt.bufPrint(&buffer, "group{d}", .{index});
                try commands.addSystem(group, added, null);
            }
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    try world.addSystem(allocator, "update", Systems.registrar, null);

    try world.runSystems(allocator);
    try std.testing.expectEqual(1, world.system_registry.groups.count());
    try std.testing.expectEqual(0, State.added_calls);

    try world.runSystems(allocator);
    try std.testing.expectEqual(group_count + 1, world.system_registry.groups.count());
    try std.testing.expectEqual(group_count, State.added_calls);
}

test "a one-shot system registered through Commands runs on the next frame" {
    const allocator = std.testing.allocator;

    const State = struct {
        var first_calls: usize = 0;
        var second_calls: usize = 0;
    };
    State.first_calls = 0;
    State.second_calls = 0;

    const Systems = struct {
        fn second() void {
            State.second_calls += 1;
        }

        fn first(commands: Commands) !void {
            State.first_calls += 1;
            try commands.addOneShotSystem(second, null);
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    try world.addOneShotSystem(allocator, Systems.first, null);

    try world.runSystems(allocator);
    try std.testing.expectEqual(1, State.first_calls);
    try std.testing.expectEqual(0, State.second_calls);

    try world.runSystems(allocator);
    try std.testing.expectEqual(1, State.first_calls);
    try std.testing.expectEqual(1, State.second_calls);

    try world.runSystems(allocator);
    try std.testing.expectEqual(1, State.first_calls);
    try std.testing.expectEqual(1, State.second_calls);
}

test "an observer registering observers for its own event does not disturb the running dispatch" {
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

    const Observers = struct {
        fn added(_: Event(Damage)) void {
            State.added_calls += 1;
        }

        fn registrar(commands: Commands, _: Event(Damage)) !void {
            State.registrar_calls += 1;
            if (State.registered) return;
            State.registered = true;
            for (0..observer_count) |_| try commands.addObserver(added, null);
        }

        fn bystander(_: Event(Damage)) void {
            State.bystander_calls += 1;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    try world.addObserver(allocator, Observers.registrar, null);
    try world.addObserver(allocator, Observers.bystander, null);

    world.trigger(allocator, Damage{ .amount = 1 });
    try std.testing.expectEqual(1, State.registrar_calls);
    try std.testing.expectEqual(1, State.bystander_calls);
    try std.testing.expectEqual(0, State.added_calls);

    try world.runSystems(allocator);

    world.trigger(allocator, Damage{ .amount = 1 });
    try std.testing.expectEqual(2, State.registrar_calls);
    try std.testing.expectEqual(2, State.bystander_calls);
    try std.testing.expectEqual(observer_count, State.added_calls);
}

test "flushSystemRegistrations applies queued registrations without running a frame" {
    const allocator = std.testing.allocator;

    const State = struct {
        var calls: usize = 0;
    };
    State.calls = 0;

    const system = struct {
        fn call() void {
            State.calls += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    try Commands.fromWorld(allocator, &world).addSystem("update", system, null);
    try std.testing.expectEqual(0, world.system_registry.groups.count());

    try world.flushSystemRegistrations(allocator);

    try std.testing.expectEqual(1, world.system_registry.groups.count());
    try std.testing.expectEqual(0, State.calls);
}

test "a plugin's build can register systems, one-shot systems and observers through Commands" {
    const allocator = std.testing.allocator;

    const Damage = struct { amount: u32 };

    const Plugin = struct {
        updates: usize = 0,
        setups: usize = 0,
        damage_seen: u32 = 0,

        pub fn build(self: *@This(), commands: Commands) !void {
            try commands.addSystem("update", update, self);
            try commands.addOneShotSystem(setup, self);
            try commands.addObserver(onDamage, self);
        }

        fn update(self: *@This()) void {
            self.updates += 1;
        }

        fn setup(self: *@This()) void {
            self.setups += 1;
        }

        fn onDamage(self: *@This(), event: Event(Damage)) !void {
            self.damage_seen += event.value.amount;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    try world.addPlugin(allocator, Plugin);

    try world.runSystems(allocator);
    try world.runSystems(allocator);
    world.trigger(allocator, Damage{ .amount = 7 });

    const plugin: *Plugin = @ptrCast(@alignCast(world.plugin_registry.plugins.items[0].plugin));
    try std.testing.expectEqual(2, plugin.updates);
    try std.testing.expectEqual(1, plugin.setups);
    try std.testing.expectEqual(7, plugin.damage_seen);
}

test "a plugin system registering a plugin system through Commands binds the same plugin" {
    const allocator = std.testing.allocator;

    const Plugin = struct {
        registered: bool = false,
        registrar_calls: usize = 0,
        added_calls: usize = 0,

        pub fn build(self: *@This(), commands: Commands) !void {
            try commands.addSystem("update", registrar, self);
        }

        fn registrar(self: *@This(), commands: Commands) !void {
            self.registrar_calls += 1;
            if (self.registered) return;
            self.registered = true;
            try commands.addSystem("late", added, self);
        }

        fn added(self: *@This()) void {
            self.added_calls += 1;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    try world.addPlugin(allocator, Plugin);
    const plugin: *Plugin = @ptrCast(@alignCast(world.plugin_registry.plugins.items[0].plugin));

    try world.runSystems(allocator);
    try std.testing.expectEqual(1, plugin.registrar_calls);
    try std.testing.expectEqual(0, plugin.added_calls);

    try world.runSystems(allocator);
    try std.testing.expectEqual(2, plugin.registrar_calls);
    try std.testing.expectEqual(1, plugin.added_calls);
}

test "Commands.addResource defers registration until the command queue is flushed" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    try Commands.fromWorld(allocator, &world).addResource(Config, .{ .scale = 2 });
    try std.testing.expectEqual(null, world.getResource(Config));

    try world.command_queue.flush(allocator, &world);

    try std.testing.expectEqual(@as(f32, 2), world.getResource(Config).?.scale);
}

test "Commands.removeResource defers removal until the command queue is flushed" {
    const allocator = std.testing.allocator;

    const State = struct {
        var deinits: usize = 0;
    };
    State.deinits = 0;

    const Tracked = struct {
        pub fn deinit(_: *@This()) void {
            State.deinits += 1;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    try world.addResource(allocator, Tracked, .{});

    try Commands.fromWorld(allocator, &world).removeResource(Tracked);
    try std.testing.expectEqual(0, State.deinits);
    try std.testing.expect(world.getResource(Tracked) != null);

    try world.command_queue.flush(allocator, &world);

    try std.testing.expectEqual(1, State.deinits);
    try std.testing.expectEqual(null, world.getResource(Tracked));
}

test "a resource removed through Commands stays readable for the rest of the group" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const State = struct {
        var seen_after_remove: ?f32 = null;
    };
    State.seen_after_remove = null;

    const Systems = struct {
        fn remover(commands: Commands, config: Resource(Config)) !void {
            try commands.removeResource(Config);
            config.value.scale += 1;
        }

        fn reader(world: *World) void {
            if (world.getResource(Config)) |config| State.seen_after_remove = config.scale;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    try world.addResource(allocator, Config, .{ .scale = 1 });
    try world.addSystem(allocator, "update", Systems.remover, null);
    try world.addSystem(allocator, "update", Systems.reader, null);

    try world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 2), State.seen_after_remove.?);
    try std.testing.expectEqual(null, world.getResource(Config));
}

test "a resource added through Commands is visible to the next group" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const State = struct {
        var seen: ?f32 = null;
    };
    State.seen = null;

    const Systems = struct {
        fn producer(commands: Commands) !void {
            try commands.addResource(Config, .{ .scale = 3 });
        }

        fn consumer(world: *World) void {
            if (world.getResource(Config)) |config| State.seen = config.scale;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    try world.addSystem(allocator, "first", Systems.producer, null);
    try world.addSystem(allocator, "second", Systems.consumer, null);

    try world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 3), State.seen.?);
}

test "a plugin's build can register a resource through Commands" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const State = struct {
        var seen: f32 = 0;
    };
    State.seen = 0;

    const Plugin = struct {
        pub fn build(_: *@This(), commands: Commands) !void {
            try commands.addResource(Config, .{ .scale = 4 });
            try commands.addSystem("update", read, null);
        }

        fn read(config: Resource(Config)) void {
            State.seen = config.value.scale;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    try world.addPlugin(allocator, Plugin);
    try std.testing.expectEqual(null, world.getResource(Config));

    try world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 4), State.seen);
}

test "CommandQueue.deinit frees an unflushed addResource value without applying it" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    try Commands.fromWorld(allocator, &world).addResource(Config, .{ .scale = 1 });

    world.command_queue.deinit(allocator);
    world.command_queue = CommandQueue.init();

    try std.testing.expectEqual(null, world.getResource(Config));
}

test "Commands.trigger dispatches observers synchronously" {
    const allocator = std.testing.allocator;

    const Damage = struct { amount: u32 };

    const State = struct {
        var seen: u32 = 0;
        var ran_before_system_returned: bool = false;
    };
    State.seen = 0;
    State.ran_before_system_returned = false;

    const onDamage = struct {
        fn call(event: Event(Damage)) void {
            State.seen = event.value.amount;
        }
    }.call;
    const system = struct {
        fn call(commands: Commands) void {
            commands.trigger(Damage{ .amount = 7 });
            State.ran_before_system_returned = State.seen == 7;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    try world.addObserver(allocator, onDamage, null);
    try world.addSystem(allocator, "update", system, null);

    try world.runSystems(allocator);

    try std.testing.expectEqual(7, State.seen);
    try std.testing.expect(State.ran_before_system_returned);
}

test "an observer reached through Commands.trigger can queue deferred work" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Spawned = struct { x: f32 };

    const State = struct {
        var entities_at_trigger: usize = 0;
    };
    State.entities_at_trigger = 0;

    const onSpawned = struct {
        fn call(commands: Commands, event: Event(Spawned)) !void {
            try commands.spawn(.{Position{ .x = event.value.x, .y = 0 }});
        }
    }.call;
    const system = struct {
        fn call(commands: Commands, world: *World) !void {
            commands.trigger(Spawned{ .x = 5 });
            State.entities_at_trigger = world.archetypes.items.len;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    try world.addObserver(allocator, onSpawned, null);
    try world.addSystem(allocator, "update", system, null);

    try world.runSystems(allocator);

    try std.testing.expectEqual(0, State.entities_at_trigger);
    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(1, world.archetypes.items[0].entity_count);
}

test "an observer reached through Commands.trigger can register another observer" {
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

    const Observers = struct {
        fn added(_: Event(Damage)) void {
            State.added_calls += 1;
        }

        fn registrar(commands: Commands, _: Event(Damage)) !void {
            State.registrar_calls += 1;
            if (State.registered) return;
            State.registered = true;
            for (0..16) |_| try commands.addObserver(added, null);
        }
    };
    const system = struct {
        fn call(commands: Commands) void {
            commands.trigger(Damage{ .amount = 1 });
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    try world.addObserver(allocator, Observers.registrar, null);
    try world.addSystem(allocator, "update", system, null);

    try world.runSystems(allocator);
    try std.testing.expectEqual(1, State.registrar_calls);
    try std.testing.expectEqual(0, State.added_calls);

    try world.runSystems(allocator);
    try std.testing.expectEqual(2, State.registrar_calls);
    try std.testing.expectEqual(16, State.added_calls);
}

test "Query.get returns pointers to the components the query declares" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(
        allocator,
        .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } },
    );

    const position, const velocity = try world.query(&.{ Position, Velocity }).get(entity);

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position.*);
    try std.testing.expectEqual(Velocity{ .dx = 3, .dy = 4 }, velocity.*);
}

test "Query.get writes through to the stored components" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(allocator, .{Position{ .x = 1, .y = 0 }});

    const position = try world.query(&.{Position}).get(entity);
    position[0].x += 10;

    const reread = try world.getEntity(entity, &.{Position});
    try std.testing.expectEqual(@as(f32, 11), reread[0].x);
}

test "Query.get returns Error.UnknownComponent for an entity outside the query" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(allocator, .{Position{ .x = 1, .y = 2 }});

    try std.testing.expectError(
        Error.UnknownComponent,
        world.query(&.{Velocity}).get(entity),
    );
}

test "Query.get returns Error.InvalidEntity for an out-of-range entity index" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    try std.testing.expectError(
        Error.InvalidEntity,
        world.query(&.{Position}).get(.{ .id = 999, .generation = 0 }),
    );
}

test "Query.get returns Error.InvalidEntity for a despawned entity" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = try world.addEntity(allocator, .{Position{ .x = 1, .y = 2 }});
    try world.removeEntity(allocator, entity);

    try std.testing.expectError(
        Error.InvalidEntity,
        world.query(&.{Position}).get(entity),
    );
}

test "a system can follow an Entity stored in a component without taking *World" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Target = struct { entity: Entity };

    const State = struct {
        var target_x: f32 = 0;
    };
    State.target_x = 0;

    const system = struct {
        fn call(targets: Query(&.{Target}), positions: Query(&.{Position})) !void {
            var it = targets.iterator();
            while (it.next()) |row| {
                const position = try positions.get(row[0].entity);
                position[0].x += 1;
                State.target_x = position[0].x;
            }
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    const target = try world.addEntity(allocator, .{Position{ .x = 5, .y = 0 }});
    _ = try world.addEntity(allocator, .{Target{ .entity = target }});

    try world.addSystem(allocator, "update", system, null);
    try world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 6), State.target_x);
    const position = try world.getEntity(target, &.{Position});
    try std.testing.expectEqual(@as(f32, 6), position[0].x);
}
