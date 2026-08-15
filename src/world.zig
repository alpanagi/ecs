const std = @import("std");

const Archetype = @import("archetype.zig").Archetype;
const ComponentData = @import("component.zig").ComponentData;
const ComponentDescriptor = @import("component.zig").ComponentDescriptor;
const ComponentPointers = @import("component.zig").ComponentPointers;
const componentId = @import("component.zig").componentId;
const componentTypes = @import("component.zig").componentTypes;
const Entity = @import("entity.zig").Entity;
const Error = @import("error.zig").Error;
const Event = @import("event.zig").Event;
const EventId = @import("event.zig").EventId;
const hashBytes = @import("hash.zig").hashBytes;
const component_events = @import("lifecycle.zig").component;
const resource_events = @import("lifecycle.zig").resource;
const ComponentAdded = @import("lifecycle.zig").ComponentAdded;
const ComponentDestroying = @import("lifecycle.zig").ComponentDestroying;
const ResourceAdded = @import("lifecycle.zig").ResourceAdded;
const ResourceDestroying = @import("lifecycle.zig").ResourceDestroying;
const Resource = @import("resource.zig").Resource;
const panic = @import("util.zig").panic;
const panicOom = @import("util.zig").panicOom;

const CommandQueue = @import("command_queue.zig").CommandQueue;
const RegistrationQueue = @import("registration_queue.zig").RegistrationQueue;
const PluginRegistry = @import("plugin_registry.zig").PluginRegistry;
const ResourceRegistry = @import("resource_registry.zig").ResourceRegistry;
const SystemRegistry = @import("system_registry.zig").SystemRegistry;
const buildObserverEntry = @import("system_entry.zig").buildObserverEntry;
const buildSystemEntry = @import("system_entry.zig").buildSystemEntry;
const SystemEntry = @import("system_entry.zig").SystemEntry;
const ObserverEntry = @import("system_entry.zig").ObserverEntry;

pub const Commands = @import("commands.zig").Commands;
pub const Query = @import("query.zig").Query;

pub const Observers = struct {
    world: *World,
    allocator: std.mem.Allocator,

    pub fn fromWorld(allocator: std.mem.Allocator, world: *World) Observers {
        return .{ .world = world, .allocator = allocator };
    }

    pub fn trigger(self: Observers, event: anytype) void {
        self.world.trigger(self.allocator, event);
    }
};

const EntityDescriptor = struct {
    generation: u32,
    archetype: ?u32,
    row: u32,
};

pub const World = struct {
    archetypes: std.ArrayList(Archetype),

    entity_descriptors: std.ArrayList(EntityDescriptor),
    entity_free_list: std.ArrayList(u32),

    system_registry: SystemRegistry,
    plugin_registry: PluginRegistry,
    resource_registry: ResourceRegistry,
    command_queue: CommandQueue,
    registration_queue: RegistrationQueue,

    pub fn init() World {
        return .{
            .archetypes = .empty,
            .entity_descriptors = .empty,
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

        self.archetypes.deinit(allocator);
        self.entity_descriptors.deinit(allocator);
        self.entity_free_list.deinit(allocator);
    }

    pub fn addEntity(self: *World, allocator: std.mem.Allocator, components: anytype) Entity {
        const types = comptime componentTypes(@TypeOf(components));

        var values: @Tuple(types) = components;
        _ = &values;

        var descriptors: [types.len]ComponentDescriptor = undefined;
        var component_data: [types.len]ComponentData = undefined;

        inline for (types, 0..) |Component, index| {
            const descriptor = ComponentDescriptor.from(Component);
            descriptors[index] = descriptor;
            component_data[index] = .{
                .id = descriptor.id,
                .bytes = if (@sizeOf(Component) == 0) null else std.mem.asBytes(&values[index]),
            };
        }

        const archetype_id = self.findOrCreateArchetype(allocator, &descriptors);
        const id = self.reserveEntityId(allocator);

        const entity = Entity{
            .id = id,
            .generation = self.entity_descriptors.items[id].generation,
        };

        const row = self.archetypes.items[archetype_id].addEntity(
            allocator,
            id,
            &component_data,
        ) catch |err| panic("World.addEntity: the archetype rejected the entity's components: {}", .{err});

        self.entity_descriptors.items[id].archetype = archetype_id;
        self.entity_descriptors.items[id].row = row;

        inline for (types, 0..) |Component, index| {
            self.system_registry.dispatch(
                allocator,
                self,
                component_events.added(Component),
                &ComponentAdded{ .entity = entity, .component = descriptors[index].id },
            );
        }

        return entity;
    }

    pub fn removeEntity(self: *World, allocator: std.mem.Allocator, entity: Entity) void {
        if (entity.id >= self.entity_descriptors.items.len) return;
        if (self.entity_descriptors.items[entity.id].generation != entity.generation) return;

        const archetype_id = self.entity_descriptors.items[entity.id].archetype.?;

        const sized_components = self.archetypes.items[archetype_id].sized_components;
        const marker_component_ids = self.archetypes.items[archetype_id].marker_component_ids;

        for (sized_components) |component| self.triggerComponentDestroying(allocator, entity, component.id);
        for (marker_component_ids) |component_id| self.triggerComponentDestroying(allocator, entity, component_id);

        const row = self.entity_descriptors.items[entity.id].row;

        if (self.archetypes.items[archetype_id].removeEntity(allocator, row)) |relocated_id| {
            self.entity_descriptors.items[relocated_id].row = row;
        }

        self.entity_descriptors.items[entity.id].generation += 1;
        self.entity_descriptors.items[entity.id].archetype = null;

        self.entity_free_list.append(allocator, entity.id) catch panicOom("World.removeEntity");
    }

    pub fn addSystem(
        self: *World,
        allocator: std.mem.Allocator,
        group: []const u8,
        comptime function: anytype,
        plugin: anytype,
    ) void {
        self.system_registry.addSystemEntry(allocator, hashBytes(group), buildSystemEntry(function, plugin));
    }

    pub fn addOneShotSystem(
        self: *World,
        allocator: std.mem.Allocator,
        comptime function: anytype,
        plugin: anytype,
    ) void {
        self.system_registry.addOneShotSystemEntry(allocator, buildSystemEntry(function, plugin));
    }

    pub fn addObserver(
        self: *World,
        allocator: std.mem.Allocator,
        event_id: EventId,
        comptime function: anytype,
        plugin: anytype,
    ) void {
        self.system_registry.addObserverEntry(allocator, event_id, buildObserverEntry(function, plugin));
    }

    pub fn addPlugin(self: *World, allocator: std.mem.Allocator, comptime T: type) void {
        self.plugin_registry.addPlugin(allocator, self, T);
    }

    pub fn addResource(
        self: *World,
        allocator: std.mem.Allocator,
        comptime T: type,
        value: T,
    ) void {
        const replacing = self.resource_registry.getResource(T) != null;
        if (replacing) {
            self.system_registry.dispatch(allocator, self, resource_events.destroying(T), &ResourceDestroying{});
        }

        self.resource_registry.addResource(allocator, T, value);

        self.system_registry.dispatch(allocator, self, resource_events.added(T), &ResourceAdded{});
    }

    pub fn getResource(self: *World, comptime T: type) ?*T {
        return self.resource_registry.getResource(T);
    }

    pub fn removeResource(self: *World, allocator: std.mem.Allocator, comptime T: type) void {
        if (self.resource_registry.getResource(T) == null) return;

        self.system_registry.dispatch(allocator, self, resource_events.destroying(T), &ResourceDestroying{});
        self.resource_registry.removeResource(allocator, T);
    }

    pub fn query(self: *World, comptime components: []const type) Query(components) {
        return .{ .world = self };
    }

    pub fn getEntity(
        self: *World,
        entity: Entity,
        comptime components: []const type,
    ) !ComponentPointers(components) {
        if (entity.id >= self.entity_descriptors.items.len) return Error.InvalidEntity;

        const descriptor = self.entity_descriptors.items[entity.id];
        if (descriptor.generation != entity.generation) return Error.InvalidEntity;

        const archetype_id = descriptor.archetype orelse return Error.InvalidEntity;

        return getComponents(&self.archetypes.items[archetype_id], descriptor.row, components);
    }

    pub fn trigger(self: *World, allocator: std.mem.Allocator, event: anytype) void {
        self.system_registry.dispatch(allocator, self, EventId.from(@TypeOf(event)), &event);
    }

    pub fn runSystems(self: *World, allocator: std.mem.Allocator) void {
        self.flushSystemRegistrations(allocator);
        self.command_queue.flush(allocator, self);

        self.system_registry.runOneShotSystems(allocator, self);
        self.command_queue.flush(allocator, self);

        var groups = self.system_registry.groupIterator();
        while (groups.next()) |group| {
            for (group) |entry| entry.run(allocator, self);
            self.command_queue.flush(allocator, self);
        }
    }

    fn flushSystemRegistrations(self: *World, allocator: std.mem.Allocator) void {
        self.registration_queue.flush(allocator, &self.system_registry);
    }

    fn findOrCreateArchetype(
        self: *World,
        allocator: std.mem.Allocator,
        components: []const ComponentDescriptor,
    ) u32 {
        for (self.archetypes.items, 0..) |*archetype, index| {
            if (archetype.sized_components.len + archetype.marker_component_ids.len != components.len) continue;

            const matches = for (components) |component| {
                if (!archetype.hasComponent(component.id)) break false;
            } else true;

            if (matches) return @intCast(index);
        }

        self.archetypes.append(allocator, Archetype.init(allocator, components, .{})) catch
            panicOom("World.findOrCreateArchetype");

        return @intCast(self.archetypes.items.len - 1);
    }

    fn reserveEntityId(self: *World, allocator: std.mem.Allocator) u32 {
        if (self.entity_free_list.pop()) |id| return id;

        self.entity_descriptors.append(allocator, .{
            .generation = 0,
            .archetype = null,
            .row = 0,
        }) catch panicOom("World.reserveEntityId");

        return @intCast(self.entity_descriptors.items.len - 1);
    }

    fn triggerComponentDestroying(
        self: *World,
        allocator: std.mem.Allocator,
        entity: Entity,
        component_id: u64,
    ) void {
        self.system_registry.dispatch(
            allocator,
            self,
            component_events.destroyingById(component_id),
            &ComponentDestroying{ .entity = entity, .component = component_id },
        );
    }
};

pub fn getComponents(
    archetype: *Archetype,
    row: u32,
    comptime components: []const type,
) !ComponentPointers(components) {
    var result: ComponentPointers(components) = undefined;

    inline for (components, 0..) |Component, index| {
        if (comptime @sizeOf(Component) == 0) {
            if (!archetype.hasComponent(componentId(Component))) return Error.UnknownComponent;
            result[index] = &struct {
                var instance: Component = .{};
            }.instance;
        } else {
            const bytes = archetype.getComponentBytes(row, componentId(Component)) orelse
                return Error.UnknownComponent;
            result[index] = @ptrCast(@alignCast(bytes.ptr));
        }
    }

    return result;
}

test "init: returns an empty world" {
    const world = World.init();

    try std.testing.expectEqual(0, world.entity_descriptors.items.len);
    try std.testing.expectEqual(0, world.archetypes.items.len);
    try std.testing.expectEqual(0, world.entity_descriptors.items.len);
    try std.testing.expectEqual(0, world.entity_descriptors.items.len);
    try std.testing.expectEqual(0, world.entity_free_list.items.len);
}

test "deinit: is safe on a freshly initialized world" {
    const allocator = std.testing.allocator;

    var world = World.init();
    world.deinit(allocator);
}

test "deinit: deinits every archetype it owns" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();

    try world.archetypes.append(allocator, Archetype.init(allocator, &.{ComponentDescriptor.from(Value)}, .{}));

    world.deinit(allocator);
}

test "addEntity: creates an entity in a new archetype" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = world.addEntity(
        allocator,
        .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } },
    );

    try std.testing.expectEqual(Entity{ .id = 0, .generation = 0 }, entity);
    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(0, world.entity_descriptors.items[0].archetype.?);
    try std.testing.expectEqual(0, world.entity_descriptors.items[0].row);
}

test "addEntity: reuses the archetype for the same component set" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const first = world.addEntity(
        allocator,
        .{ Position{ .x = 1, .y = 1 }, Velocity{ .dx = 1, .dy = 1 } },
    );
    const second = world.addEntity(
        allocator,
        .{ Position{ .x = 2, .y = 2 }, Velocity{ .dx = 2, .dy = 2 } },
    );

    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(
        world.entity_descriptors.items[first.id].archetype.?,
        world.entity_descriptors.items[second.id].archetype.?,
    );
    try std.testing.expectEqual(0, world.entity_descriptors.items[first.id].row);
    try std.testing.expectEqual(1, world.entity_descriptors.items[second.id].row);
}

test "addEntity: stores the entity's component values" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = world.addEntity(allocator, .{Position{ .x = 5, .y = 6 }});

    const archetype_id = world.entity_descriptors.items[entity.id].archetype.?;
    const archetype_slot = world.entity_descriptors.items[entity.id].row;

    const position = try getComponents(&world.archetypes.items[archetype_id], archetype_slot, &.{Position});

    try std.testing.expectEqual(Position{ .x = 5, .y = 6 }, position[0].*);
}

test "addEntity: creates an entity from three component types" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: u32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = world.addEntity(allocator, .{
        Position{ .x = 1, .y = 2 },
        Velocity{ .dx = 3, .dy = 4 },
        Health{ .hp = 100 },
    });

    const archetype_id = world.entity_descriptors.items[entity.id].archetype.?;
    const archetype_slot = world.entity_descriptors.items[entity.id].row;

    const position, const velocity, const health = try getComponents(
        &world.archetypes.items[archetype_id],
        archetype_slot,
        &.{ Position, Velocity, Health },
    );

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position.*);
    try std.testing.expectEqual(Velocity{ .dx = 3, .dy = 4 }, velocity.*);
    try std.testing.expectEqual(Health{ .hp = 100 }, health.*);
}

test "addEntity: creates the entity immediately" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{Position{ .x = 1, .y = 2 }});

    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(1, world.archetypes.items[0].entity_count);
}

test "addEntity: triggers ComponentAdded for each component" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const State = struct {
        var position_entity: ?Entity = null;
        var velocity_entity: ?Entity = null;
    };
    const onPositionAdded = struct {
        fn call(event: Event(ComponentAdded)) void {
            State.position_entity = event.value.entity;
        }
    }.call;
    const onVelocityAdded = struct {
        fn call(event: Event(ComponentAdded)) void {
            State.velocity_entity = event.value.entity;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    world.addObserver(allocator, component_events.added(Position), onPositionAdded, null);
    world.addObserver(allocator, component_events.added(Velocity), onVelocityAdded, null);

    const entity = world.addEntity(allocator, .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } });

    try std.testing.expectEqual(entity, State.position_entity);
    try std.testing.expectEqual(entity, State.velocity_entity);
}

test "addEntity: triggers nothing for a component with no observer" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const State = struct {
        var position_entity: ?Entity = null;
    };
    const onPositionAdded = struct {
        fn call(event: Event(ComponentAdded)) void {
            State.position_entity = event.value.entity;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    world.addObserver(allocator, component_events.added(Position), onPositionAdded, null);

    _ = world.addEntity(allocator, .{Velocity{ .dx = 1, .dy = 1 }});

    try std.testing.expectEqual(null, State.position_entity);
}

test "addEntity: triggers lifecycle events for a marker component" {
    const allocator = std.testing.allocator;

    const Player = struct {};

    const State = struct {
        var added: usize = 0;
        var destroying: usize = 0;
    };
    State.added = 0;
    State.destroying = 0;

    const Handlers = struct {
        fn onAdded(_: Event(ComponentAdded)) void {
            State.added += 1;
        }

        fn onDestroying(_: Event(ComponentDestroying)) void {
            State.destroying += 1;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    world.addObserver(allocator, component_events.added(Player), Handlers.onAdded, null);
    world.addObserver(allocator, component_events.destroying(Player), Handlers.onDestroying, null);

    const entity = world.addEntity(allocator, .{Player{}});
    try std.testing.expectEqual(1, State.added);
    try std.testing.expectEqual(0, State.destroying);

    world.removeEntity(allocator, entity);
    try std.testing.expectEqual(1, State.destroying);
}

test "removeEntity: does nothing for an out of range entity id" {
    const allocator = std.testing.allocator;

    var world = World.init();
    defer world.deinit(allocator);

    world.removeEntity(allocator, .{ .id = 999, .generation = 0 });

    try std.testing.expectEqual(0, world.entity_descriptors.items.len);
}

test "removeEntity: does nothing for a stale generation" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = world.addEntity(allocator, .{Value{ .value = 1 }});

    world.removeEntity(allocator, entity);
    // entity is now stale (generation bumped); removing it again must be a
    // no-op, not a double-free or a second attempt to relocate anything.
    world.removeEntity(allocator, entity);

    try std.testing.expectEqual(entity.generation + 1, world.entity_descriptors.items[entity.id].generation);
}

test "removeEntity: marks the descriptor dead and recycles its id" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = world.addEntity(allocator, .{Value{ .value = 1 }});

    world.removeEntity(allocator, entity);

    try std.testing.expectEqual(entity.generation + 1, world.entity_descriptors.items[entity.id].generation);
    try std.testing.expectEqual(null, world.entity_descriptors.items[entity.id].archetype);
    try std.testing.expectEqual(1, world.entity_free_list.items.len);
    try std.testing.expectEqual(entity.id, world.entity_free_list.items[0]);
}

test "removeEntity: fixes up the relocated entity's row" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();
    defer world.deinit(allocator);

    const first = world.addEntity(allocator, .{Value{ .value = 1 }});
    _ = world.addEntity(allocator, .{Value{ .value = 2 }});
    const third = world.addEntity(allocator, .{Value{ .value = 3 }});

    world.removeEntity(allocator, first);

    // third was the last entity in the archetype, so it should have been
    // swapped into first's now-vacated archetype slot.
    try std.testing.expectEqual(0, world.entity_descriptors.items[third.id].row);
}

test "removeEntity: deinits memory owned by the removed entity's components" {
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
    const entity = world.addEntity(allocator, .{owning});

    world.removeEntity(allocator, entity);
}

test "removeEntity: bumps the generation before the id is reused" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();
    defer world.deinit(allocator);

    const first = world.addEntity(allocator, .{Value{ .value = 1 }});
    world.removeEntity(allocator, first);

    const second = world.addEntity(allocator, .{Value{ .value = 2 }});

    try std.testing.expectEqual(first.id, second.id);
    try std.testing.expectEqual(first.generation + 1, second.generation);
}

test "removeEntity: triggers ComponentDestroying for each component" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const State = struct {
        var destroying_entity: ?Entity = null;
    };
    const onPositionDestroying = struct {
        fn call(event: Event(ComponentDestroying)) void {
            State.destroying_entity = event.value.entity;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    world.addObserver(allocator, component_events.destroying(Position), onPositionDestroying, null);

    const entity = world.addEntity(allocator, .{Position{ .x = 1, .y = 2 }});
    world.removeEntity(allocator, entity);

    try std.testing.expectEqual(entity, State.destroying_entity);
}

test "removeEntity: triggers ComponentDestroying while the component is readable" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const State = struct {
        var observed: ?Position = null;
    };
    const onPositionDestroying = struct {
        fn call(positions: Query(&.{Position}), event: Event(ComponentDestroying)) void {
            const components = positions.get(event.value.entity) catch return;
            State.observed = components[0].*;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    world.addObserver(allocator, component_events.destroying(Position), onPositionDestroying, null);

    const entity = world.addEntity(allocator, .{Position{ .x = 1, .y = 2 }});
    world.removeEntity(allocator, entity);

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, State.observed);
}

test "removeEntity: leaves a marker intact after another entity is swapped out" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const first = world.addEntity(allocator, .{ Player{}, Position{ .x = 1, .y = 1 } });
    const second = world.addEntity(allocator, .{ Player{}, Position{ .x = 2, .y = 2 } });

    world.removeEntity(allocator, first);

    const position = try world.getEntity(second, &.{ Player, Position });
    try std.testing.expectEqual(Position{ .x = 2, .y = 2 }, position[1].*);
}

test "addSystem: registers a system that runSystems then runs" {
    const State = struct {
        var called = false;
    };
    const system = struct {
        fn call(_: std.mem.Allocator) void {
            State.called = true;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    world.addSystem(std.testing.allocator, "physics", system, null);

    world.runSystems(std.testing.allocator);
    try std.testing.expect(State.called);
}

test "addSystem: groups systems by name in call order" {
    const State = struct {
        var calls: [2]u8 = undefined;
        var count: usize = 0;
    };
    const a = struct {
        fn call(_: std.mem.Allocator) void {
            State.calls[State.count] = 1;
            State.count += 1;
        }
    }.call;
    const b = struct {
        fn call(_: std.mem.Allocator) void {
            State.calls[State.count] = 2;
            State.count += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    world.addSystem(std.testing.allocator, "physics", a, null);
    world.addSystem(std.testing.allocator, "physics", b, null);

    world.runSystems(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &State.calls);
}

test "addPlugin: runs the plugin's init immediately" {
    const State = struct {
        var initialized: bool = false;
    };
    const Plugin = struct {
        pub fn init(_: std.mem.Allocator) @This() {
            State.initialized = true;
            return .{};
        }

        pub fn build(_: *@This(), _: std.mem.Allocator) void {}
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    world.addPlugin(std.testing.allocator, Plugin);

    try std.testing.expect(State.initialized);
}

test "addResource: stores a value that getResource returns" {
    const ClearColor = struct { r: f32, g: f32, b: f32 };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    world.addResource(std.testing.allocator, ClearColor, .{ .r = 0, .g = 1, .b = 0 });

    const color = world.getResource(ClearColor).?;
    try std.testing.expectEqual(ClearColor{ .r = 0, .g = 1, .b = 0 }, color.*);
}

test "addResource: triggers ResourceAdded" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const State = struct {
        var calls: usize = 0;
    };
    State.calls = 0;

    const onAdded = struct {
        fn call(_: Event(ResourceAdded)) void {
            State.calls += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    world.addObserver(allocator, resource_events.added(Config), onAdded, null);
    world.addResource(allocator, Config, .{ .scale = 1 });

    try std.testing.expectEqual(1, State.calls);
}

test "addResource: triggers Destroying for the old value then Added for the new" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const State = struct {
        var log: [4]u8 = undefined;
        var count: usize = 0;
        var scale_at_destroying: ?f32 = null;
        var scale_at_added: ?f32 = null;
    };
    State.count = 0;
    State.scale_at_destroying = null;
    State.scale_at_added = null;

    const Handlers = struct {
        fn onAdded(config: Resource(Config), _: Event(ResourceAdded)) void {
            State.log[State.count] = 1;
            State.count += 1;
            State.scale_at_added = config.value.scale;
        }

        fn onDestroying(config: Resource(Config), _: Event(ResourceDestroying)) void {
            State.log[State.count] = 2;
            State.count += 1;
            State.scale_at_destroying = config.value.scale;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    world.addObserver(allocator, resource_events.added(Config), Handlers.onAdded, null);
    world.addObserver(allocator, resource_events.destroying(Config), Handlers.onDestroying, null);

    world.addResource(allocator, Config, .{ .scale = 1 });
    world.addResource(allocator, Config, .{ .scale = 2 });

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 1 }, State.log[0..State.count]);
    try std.testing.expectEqual(@as(f32, 1), State.scale_at_destroying.?);
    try std.testing.expectEqual(@as(f32, 2), State.scale_at_added.?);
}

test "addResource: does not trigger component events for the same type" {
    const allocator = std.testing.allocator;

    const Shared = struct { value: u32 };

    const State = struct {
        var resource_added: usize = 0;
        var component_added: usize = 0;
    };
    State.resource_added = 0;
    State.component_added = 0;

    const Handlers = struct {
        fn onResource(_: Event(ResourceAdded)) void {
            State.resource_added += 1;
        }

        fn onComponent(_: Event(ComponentAdded)) void {
            State.component_added += 1;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    world.addObserver(allocator, resource_events.added(Shared), Handlers.onResource, null);
    world.addObserver(allocator, component_events.added(Shared), Handlers.onComponent, null);

    _ = world.addEntity(allocator, .{Shared{ .value = 1 }});
    try std.testing.expectEqual(1, State.component_added);
    try std.testing.expectEqual(0, State.resource_added);

    world.addResource(allocator, Shared, .{ .value = 2 });
    try std.testing.expectEqual(1, State.component_added);
    try std.testing.expectEqual(1, State.resource_added);
}

test "removeResource: removes the resource and calls its deinit" {
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

    world.addResource(std.testing.allocator, Tracked, .{});
    world.removeResource(std.testing.allocator, Tracked);

    try std.testing.expectEqual(1, State.count);
    try std.testing.expectEqual(null, world.getResource(Tracked));
}

test "removeResource: triggers ResourceDestroying while the value is readable" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const State = struct {
        var seen: ?f32 = null;
    };
    State.seen = null;

    const onDestroying = struct {
        fn call(config: Resource(Config), _: Event(ResourceDestroying)) void {
            State.seen = config.value.scale;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    world.addObserver(allocator, resource_events.destroying(Config), onDestroying, null);
    world.addResource(allocator, Config, .{ .scale = 5 });
    world.removeResource(allocator, Config);

    try std.testing.expectEqual(@as(f32, 5), State.seen.?);
    try std.testing.expectEqual(null, world.getResource(Config));
}

test "removeResource: triggers nothing for an absent resource" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const State = struct {
        var calls: usize = 0;
    };
    State.calls = 0;

    const onDestroying = struct {
        fn call(_: Event(ResourceDestroying)) void {
            State.calls += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    world.addObserver(allocator, resource_events.destroying(Config), onDestroying, null);
    world.removeResource(allocator, Config);

    try std.testing.expectEqual(0, State.calls);
}

test "getEntity: returns pointers to the requested components" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = world.addEntity(
        allocator,
        .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } },
    );

    const position, const velocity = try world.getEntity(entity, &.{ Position, Velocity });

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position.*);
    try std.testing.expectEqual(Velocity{ .dx = 3, .dy = 4 }, velocity.*);
}

test "getEntity: returns InvalidEntity for an out of range entity id" {
    const allocator = std.testing.allocator;

    var world = World.init();
    defer world.deinit(allocator);

    try std.testing.expectError(
        Error.InvalidEntity,
        world.getEntity(.{ .id = 999, .generation = 0 }, &.{}),
    );
}

test "getEntity: returns InvalidEntity for a stale generation" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = world.addEntity(allocator, .{Value{ .value = 1 }});
    world.removeEntity(allocator, entity);

    try std.testing.expectError(
        Error.InvalidEntity,
        world.getEntity(entity, &.{Value}),
    );
}

test "getEntity: returns UnknownComponent for a component the entity lacks" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = world.addEntity(allocator, .{Position{ .x = 1, .y = 2 }});

    try std.testing.expectError(
        Error.UnknownComponent,
        world.getEntity(entity, &.{Velocity}),
    );
}

test "getEntity: returns UnknownComponent for a marker the entity lacks" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = world.addEntity(allocator, .{Position{ .x = 1, .y = 2 }});

    try std.testing.expectError(
        Error.UnknownComponent,
        world.getEntity(entity, &.{ Player, Position }),
    );
}

test "trigger: runs an observer registered through addObserver" {
    const Damage = struct { amount: u32 };
    const State = struct {
        var seen: u32 = 0;
    };
    const onDamage = struct {
        fn call(event: Event(Damage)) void {
            State.seen = event.value.amount;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    world.addObserver(std.testing.allocator, EventId.from(Damage), onDamage, null);
    world.trigger(std.testing.allocator, Damage{ .amount = 7 });

    try std.testing.expectEqual(7, State.seen);
}

test "trigger: dispatches synchronously through Observers" {
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
        fn call(observers: Observers) void {
            observers.trigger(Damage{ .amount = 7 });
            State.ran_before_system_returned = State.seen == 7;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    world.addObserver(allocator, EventId.from(Damage), onDamage, null);
    world.addSystem(allocator, "update", system, null);

    world.runSystems(allocator);

    try std.testing.expectEqual(7, State.seen);
    try std.testing.expect(State.ran_before_system_returned);
}

test "runSystems: runs a one shot system exactly once" {
    const State = struct {
        var calls: usize = 0;
    };
    const system = struct {
        fn call(_: std.mem.Allocator) void {
            State.calls += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    world.addOneShotSystem(std.testing.allocator, system, null);
    world.runSystems(std.testing.allocator);
    world.runSystems(std.testing.allocator);

    try std.testing.expectEqual(1, State.calls);
}

test "runSystems: flushes commands queued by a system after each group" {
    const Position = struct { x: f32, y: f32 };

    const system = struct {
        fn call(commands: Commands) void {
            commands.spawn(.{Position{ .x = 1, .y = 2 }});
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    world.addSystem(std.testing.allocator, "spawn", system, null);
    world.runSystems(std.testing.allocator);

    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(1, world.archetypes.items[0].entity_count);
}

test "flushSystemRegistrations: applies queued registrations without running a frame" {
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

    Commands.fromWorld(allocator, &world).addSystem("update", system, null);
    try std.testing.expectEqual(0, world.system_registry.groups.count());

    world.flushSystemRegistrations(allocator);

    try std.testing.expectEqual(1, world.system_registry.groups.count());
    try std.testing.expectEqual(0, State.calls);
}

test "findOrCreateArchetype: creates an archetype for an unseen component set" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const index = world.findOrCreateArchetype(allocator, &.{ ComponentDescriptor.from(Position), ComponentDescriptor.from(Velocity) });

    try std.testing.expectEqual(0, index);
    try std.testing.expectEqual(1, world.archetypes.items.len);
}

test "findOrCreateArchetype: returns the existing archetype for a known component set" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const first_index = world.findOrCreateArchetype(allocator, &.{ ComponentDescriptor.from(Position), ComponentDescriptor.from(Velocity) });
    const second_index = world.findOrCreateArchetype(allocator, &.{ ComponentDescriptor.from(Velocity), ComponentDescriptor.from(Position) });

    try std.testing.expectEqual(first_index, second_index);
    try std.testing.expectEqual(1, world.archetypes.items.len);
}

test "findOrCreateArchetype: creates separate archetypes for different component sets" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const first_index = world.findOrCreateArchetype(allocator, &.{ComponentDescriptor.from(Position)});
    const second_index = world.findOrCreateArchetype(allocator, &.{ ComponentDescriptor.from(Position), ComponentDescriptor.from(Velocity) });

    try std.testing.expect(first_index != second_index);
    try std.testing.expectEqual(2, world.archetypes.items.len);
}

test "findOrCreateArchetype: keeps archetypes with different marker sets apart" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const Frozen = struct {};
    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{Position{ .x = 1, .y = 1 }});
    _ = world.addEntity(allocator, .{ Player{}, Position{ .x = 2, .y = 2 } });
    _ = world.addEntity(allocator, .{ Frozen{}, Position{ .x = 3, .y = 3 } });

    try std.testing.expectEqual(3, world.archetypes.items.len);

    const player_position = world.query(&.{ Player, Position }).first().?[1];
    try std.testing.expectEqual(Position{ .x = 2, .y = 2 }, player_position.*);

    const frozen_position = world.query(&.{ Frozen, Position }).first().?[1];
    try std.testing.expectEqual(Position{ .x = 3, .y = 3 }, frozen_position.*);
}

test "findOrCreateArchetype: reuses the archetype for the same marker set" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{ Player{}, Position{ .x = 1, .y = 1 } });
    _ = world.addEntity(allocator, .{ Player{}, Position{ .x = 2, .y = 2 } });
    _ = world.addEntity(allocator, .{ Player{}, Position{ .x = 3, .y = 3 } });

    try std.testing.expectEqual(1, world.archetypes.items.len);

    var it = world.query(&.{ Player, Position }).iterator();
    var matched: usize = 0;
    while (it.next()) |_| matched += 1;

    try std.testing.expectEqual(3, matched);
}

test "reserveEntityId: returns increasing ids when the free list is empty" {
    const allocator = std.testing.allocator;

    var world = World.init();
    defer world.deinit(allocator);

    const first = world.reserveEntityId(allocator);
    const second = world.reserveEntityId(allocator);

    try std.testing.expectEqual(0, first);
    try std.testing.expectEqual(1, second);
    try std.testing.expectEqual(2, world.entity_descriptors.items.len);
    try std.testing.expectEqual(2, world.entity_descriptors.items.len);
    try std.testing.expectEqual(2, world.entity_descriptors.items.len);
    try std.testing.expectEqual(0, world.entity_descriptors.items[0].generation);
    try std.testing.expectEqual(null, world.entity_descriptors.items[0].archetype);
}

test "reserveEntityId: reuses a recycled id instead of growing" {
    const allocator = std.testing.allocator;

    var world = World.init();
    defer world.deinit(allocator);

    // Simulate an already-allocated, now-dead slot at index 0.
    try world.entity_descriptors.append(allocator, .{ .generation = 1, .archetype = null, .row = 0 });
    try world.entity_free_list.append(allocator, 0);

    const index = world.reserveEntityId(allocator);

    try std.testing.expectEqual(0, index);
    try std.testing.expectEqual(1, world.entity_descriptors.items.len);
}

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

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{Position{ .x = 1, .y = 0 }});
    _ = world.addEntity(allocator, .{Position{ .x = 2, .y = 0 }});

    world.addSystem(allocator, "update", system, null);
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
        var saw_commands: bool = false;
    };
    State.positions = 0;
    State.velocities = 0;
    State.saw_commands = false;

    const system = struct {
        fn call(
            velocities: Query(&.{Velocity}),
            commands: Commands,
            _: std.mem.Allocator,
            positions: Query(&.{Position}),
        ) void {
            State.saw_commands = @TypeOf(commands) == Commands;

            var v = velocities.iterator();
            while (v.next()) |_| State.velocities += 1;

            var p = positions.iterator();
            while (p.next()) |_| State.positions += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{Position{ .x = 1, .y = 1 }});
    _ = world.addEntity(allocator, .{ Position{ .x = 2, .y = 2 }, Velocity{ .dx = 1, .dy = 1 } });

    world.addSystem(allocator, "update", system, null);
    world.runSystems(allocator);

    try std.testing.expectEqual(2, State.positions);
    try std.testing.expectEqual(1, State.velocities);
    try std.testing.expect(State.saw_commands);
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

    var world = World.init();
    defer world.deinit(allocator);

    const entity = world.addEntity(allocator, .{Position{ .x = 1, .y = 0 }});

    world.addSystem(allocator, "update", system, null);
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

    var world = World.init();
    defer world.deinit(allocator);

    world.addResource(allocator, Gravity, .{ .value = 2 });
    const entity = world.addEntity(allocator, .{Position{ .x = 0, .y = 10 }});
    world.addSystem(allocator, "update", system, null);

    world.runSystems(allocator);

    const position = try world.getEntity(entity, &.{Position});
    try std.testing.expectEqual(@as(f32, 8), position[0].y);
}

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

        pub fn build(self: *@This(), commands: Commands) void {
            commands.addSystem("update", move, self);
            commands.addObserver(EventId.from(Damage), onDamage, self);
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

    var world = World.init();
    defer world.deinit(allocator);

    _ = world.addEntity(allocator, .{Position{ .x = 0, .y = 0 }});
    _ = world.addEntity(allocator, .{Position{ .x = 5, .y = 0 }});

    world.addPlugin(allocator, Plugin);
    world.runSystems(allocator);
    world.trigger(allocator, Damage{ .amount = 7 });

    const plugin = world.plugin_registry.plugins.items[0];
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
            _ = world.world.addEntity(plugin_allocator, .{Position{ .x = 1, .y = 1 }});
            _ = world.world.addEntity(plugin_allocator, .{Position{ .x = 2, .y = 2 }});
        }

        pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
            const query = self.world.query(&.{Position});
            var it = query.iterator();
            while (it.next()) |_| State.seen += 1;
        }
    };

    var world = World.init();
    world.addPlugin(allocator, Plugin);
    world.deinit(allocator);

    try std.testing.expectEqual(2, State.seen);
}

test "integration: a plugin's build can register systems" {
    const Plugin = struct {
        calls: usize = 0,

        pub fn init(_: std.mem.Allocator) @This() {
            return .{};
        }

        pub fn build(self: *@This(), commands: Commands) void {
            commands.addSystem("update", system, self);
        }

        fn system(self: *@This(), _: std.mem.Allocator) void {
            self.calls += 1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    world.addPlugin(std.testing.allocator, Plugin);

    world.runSystems(std.testing.allocator);
    const entry: SystemEntry = world.system_registry.groups.values()[0].items[0];
    const plugin: *Plugin = @ptrCast(@alignCast(entry.plugin_function.plugin));
    try std.testing.expectEqual(1, plugin.calls);
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

    var world = World.init();
    world.addPlugin(std.testing.allocator, Plugin);
    world.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, State.count);
}

test "integration: plugin systems share state across runs" {
    const Plugin = struct {
        count: usize = 0,

        pub fn init(_: std.mem.Allocator) @This() {
            return .{};
        }

        pub fn build(self: *@This(), commands: Commands) void {
            commands.addSystem("update", increment, self);
            commands.addSystem("observe", increment, self);
        }

        fn increment(self: *@This(), _: std.mem.Allocator) void {
            self.count += 1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    world.addPlugin(std.testing.allocator, Plugin);

    world.runSystems(std.testing.allocator);
    world.runSystems(std.testing.allocator);

    const first_entry = world.system_registry.groups.values()[0].items[0].plugin_function;
    const plugin: *Plugin = @ptrCast(@alignCast(first_entry.plugin));
    try std.testing.expectEqual(4, plugin.count);
    const second_entry = world.system_registry.groups.values()[1].items[0].plugin_function;
    try std.testing.expectEqual(first_entry.plugin, second_entry.plugin);
}

test "integration: a plugin's build can register an observer through Commands" {
    const Damage = struct { amount: u32 };
    const Plugin = struct {
        total: u32 = 0,

        pub fn build(self: *@This(), commands: Commands) void {
            commands.addObserver(EventId.from(Damage), onDamage, self);
        }

        fn onDamage(self: *@This(), event: Event(Damage)) void {
            self.total += event.value.amount;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    world.addPlugin(std.testing.allocator, Plugin);
    world.flushSystemRegistrations(std.testing.allocator);
    world.trigger(std.testing.allocator, Damage{ .amount = 5 });

    const entry = world.system_registry.observers.values()[0].items[0];
    const plugin: *Plugin = @ptrCast(@alignCast(entry.plugin_function.plugin));
    try std.testing.expectEqual(5, plugin.total);
}

test "integration: a plugin's build registers a one shot system" {
    const Plugin = struct {
        calls: usize = 0,

        pub fn build(self: *@This(), commands: Commands) void {
            commands.addOneShotSystem(tick, self);
        }

        fn tick(self: *@This(), _: std.mem.Allocator) void {
            self.calls += 1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    world.addPlugin(std.testing.allocator, Plugin);
    world.runSystems(std.testing.allocator);

    const plugin: *Plugin = @ptrCast(@alignCast(world.plugin_registry.plugins.items[0].plugin));
    try std.testing.expectEqual(1, plugin.calls);
}

test "integration: a plugin's build can register a resource, read later by a system" {
    const ClearColor = struct { r: f32, g: f32, b: f32 };
    const ConfigPlugin = struct {
        pub fn build(_: *@This(), commands: Commands) void {
            commands.addResource(ClearColor, .{ .r = 1, .g = 1, .b = 1 });
            commands.addSystem("update", fadeToBlack, null);
        }

        fn fadeToBlack(color: Resource(ClearColor)) void {
            color.value.r -= 0.1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    world.addPlugin(std.testing.allocator, ConfigPlugin);
    world.runSystems(std.testing.allocator);
    world.runSystems(std.testing.allocator);

    const color = world.getResource(ClearColor).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), color.r, 0.0001);
}

test "integration: a spawn through Commands triggers Added at the flush" {
    const Position = struct { x: f32, y: f32 };

    const State = struct {
        var added_entity: ?Entity = null;
    };
    const onPositionAdded = struct {
        fn call(event: Event(ComponentAdded)) void {
            State.added_entity = event.value.entity;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    world.addObserver(std.testing.allocator, component_events.added(Position), onPositionAdded, null);
    Commands.fromWorld(std.testing.allocator, &world).spawn(.{Position{ .x = 1, .y = 2 }});
    try std.testing.expectEqual(null, State.added_entity);

    world.runSystems(std.testing.allocator);

    try std.testing.expect(State.added_entity != null);
}

test "integration: a system registered through Commands into an existing group first runs on the next frame" {
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

        fn registrar(commands: Commands) void {
            State.registrar_calls += 1;
            if (State.registered) return;
            State.registered = true;
            for (0..system_count) |_| commands.addSystem("update", added, null);
        }

        fn bystander() void {
            State.bystander_calls += 1;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    world.addSystem(allocator, "update", Systems.registrar, null);
    world.addSystem(allocator, "update", Systems.bystander, null);

    world.runSystems(allocator);
    try std.testing.expectEqual(1, State.registrar_calls);
    try std.testing.expectEqual(1, State.bystander_calls);
    try std.testing.expectEqual(0, State.added_calls);

    world.runSystems(allocator);
    try std.testing.expectEqual(2, State.registrar_calls);
    try std.testing.expectEqual(2, State.bystander_calls);
    try std.testing.expectEqual(system_count, State.added_calls);
}

test "integration: a system registered through Commands into a new group first runs on the next frame" {
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

        fn registrar(commands: Commands) void {
            if (State.registered) return;
            State.registered = true;
            for (0..group_count) |index| {
                var buffer: [16]u8 = undefined;
                const group = std.fmt.bufPrint(&buffer, "group{d}", .{index}) catch unreachable;
                commands.addSystem(group, added, null);
            }
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    world.addSystem(allocator, "update", Systems.registrar, null);

    world.runSystems(allocator);
    try std.testing.expectEqual(1, world.system_registry.groups.count());
    try std.testing.expectEqual(0, State.added_calls);

    world.runSystems(allocator);
    try std.testing.expectEqual(group_count + 1, world.system_registry.groups.count());
    try std.testing.expectEqual(group_count, State.added_calls);
}

test "integration: a one-shot system registered through Commands runs on the next frame" {
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

        fn first(commands: Commands) void {
            State.first_calls += 1;
            commands.addOneShotSystem(second, null);
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    world.addOneShotSystem(allocator, Systems.first, null);

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

        fn registrar(commands: Commands, _: Event(Damage)) void {
            State.registrar_calls += 1;
            if (State.registered) return;
            State.registered = true;
            for (0..observer_count) |_| commands.addObserver(EventId.from(Damage), added, null);
        }

        fn bystander(_: Event(Damage)) void {
            State.bystander_calls += 1;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    world.addObserver(allocator, EventId.from(Damage), Handlers.registrar, null);
    world.addObserver(allocator, EventId.from(Damage), Handlers.bystander, null);

    world.trigger(allocator, Damage{ .amount = 1 });
    try std.testing.expectEqual(1, State.registrar_calls);
    try std.testing.expectEqual(1, State.bystander_calls);
    try std.testing.expectEqual(0, State.added_calls);

    world.runSystems(allocator);

    world.trigger(allocator, Damage{ .amount = 1 });
    try std.testing.expectEqual(2, State.registrar_calls);
    try std.testing.expectEqual(2, State.bystander_calls);
    try std.testing.expectEqual(observer_count, State.added_calls);
}

test "integration: a plugin's build can register systems, one-shot systems and observers through Commands" {
    const allocator = std.testing.allocator;

    const Damage = struct { amount: u32 };

    const Plugin = struct {
        updates: usize = 0,
        setups: usize = 0,
        damage_seen: u32 = 0,

        pub fn build(self: *@This(), commands: Commands) void {
            commands.addSystem("update", update, self);
            commands.addOneShotSystem(setup, self);
            commands.addObserver(EventId.from(Damage), onDamage, self);
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

    var world = World.init();
    defer world.deinit(allocator);

    world.addPlugin(allocator, Plugin);

    world.runSystems(allocator);
    world.runSystems(allocator);
    world.trigger(allocator, Damage{ .amount = 7 });

    const plugin: *Plugin = @ptrCast(@alignCast(world.plugin_registry.plugins.items[0].plugin));
    try std.testing.expectEqual(2, plugin.updates);
    try std.testing.expectEqual(1, plugin.setups);
    try std.testing.expectEqual(7, plugin.damage_seen);
}

test "integration: a plugin system registering a plugin system through Commands binds the same plugin" {
    const allocator = std.testing.allocator;

    const Plugin = struct {
        registered: bool = false,
        registrar_calls: usize = 0,
        added_calls: usize = 0,

        pub fn build(self: *@This(), commands: Commands) void {
            commands.addSystem("update", registrar, self);
        }

        fn registrar(self: *@This(), commands: Commands) void {
            self.registrar_calls += 1;
            if (self.registered) return;
            self.registered = true;
            commands.addSystem("late", added, self);
        }

        fn added(self: *@This()) void {
            self.added_calls += 1;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    world.addPlugin(allocator, Plugin);
    const plugin: *Plugin = @ptrCast(@alignCast(world.plugin_registry.plugins.items[0].plugin));

    world.runSystems(allocator);
    try std.testing.expectEqual(1, plugin.registrar_calls);
    try std.testing.expectEqual(0, plugin.added_calls);

    world.runSystems(allocator);
    try std.testing.expectEqual(2, plugin.registrar_calls);
    try std.testing.expectEqual(1, plugin.added_calls);
}

test "integration: a resource removed through Commands stays readable for the rest of the group" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const State = struct {
        var seen_after_remove: ?f32 = null;
    };
    State.seen_after_remove = null;

    const Systems = struct {
        fn remover(commands: Commands, config: Resource(Config)) void {
            commands.removeResource(Config);
            config.value.scale += 1;
        }

        fn reader(config: Resource(Config)) void {
            State.seen_after_remove = config.value.scale;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    world.addResource(allocator, Config, .{ .scale = 1 });
    world.addSystem(allocator, "update", Systems.remover, null);
    world.addSystem(allocator, "update", Systems.reader, null);

    world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 2), State.seen_after_remove.?);
    try std.testing.expectEqual(null, world.getResource(Config));
}

test "integration: a resource added through Commands is visible to the next group" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const State = struct {
        var seen: ?f32 = null;
    };
    State.seen = null;

    const Systems = struct {
        fn producer(commands: Commands) void {
            commands.addResource(Config, .{ .scale = 3 });
        }

        fn consumer(config: Resource(Config)) void {
            State.seen = config.value.scale;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    world.addSystem(allocator, "first", Systems.producer, null);
    world.addSystem(allocator, "second", Systems.consumer, null);

    world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 3), State.seen.?);
}

test "integration: a plugin's build can register a resource through Commands" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const State = struct {
        var seen: f32 = 0;
    };
    State.seen = 0;

    const Plugin = struct {
        pub fn build(_: *@This(), commands: Commands) void {
            commands.addResource(Config, .{ .scale = 4 });
            commands.addSystem("update", read, null);
        }

        fn read(config: Resource(Config)) void {
            State.seen = config.value.scale;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    world.addPlugin(allocator, Plugin);
    try std.testing.expectEqual(null, world.getResource(Config));

    world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 4), State.seen);
}

test "integration: an unflushed addResource value is freed without being applied" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    Commands.fromWorld(allocator, &world).addResource(Config, .{ .scale = 1 });

    world.command_queue.deinit(allocator);
    world.command_queue = CommandQueue.init();

    try std.testing.expectEqual(null, world.getResource(Config));
}

test "integration: an observer reached through Observers.trigger can queue deferred work" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Spawned = struct { x: f32 };

    const State = struct {
        var entities_at_trigger: usize = 0;
    };
    State.entities_at_trigger = 0;

    const onSpawned = struct {
        fn call(commands: Commands, event: Event(Spawned)) void {
            commands.spawn(.{Position{ .x = event.value.x, .y = 0 }});
        }
    }.call;
    const system = struct {
        fn call(observers: Observers, positions: Query(&.{Position})) void {
            observers.trigger(Spawned{ .x = 5 });
            var it = positions.iterator();
            while (it.next()) |_| State.entities_at_trigger += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    world.addObserver(allocator, EventId.from(Spawned), onSpawned, null);
    world.addSystem(allocator, "update", system, null);

    world.runSystems(allocator);

    try std.testing.expectEqual(0, State.entities_at_trigger);
    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(1, world.archetypes.items[0].entity_count);
}

test "integration: an observer reached through Observers.trigger can register another observer" {
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

        fn registrar(commands: Commands, _: Event(Damage)) void {
            State.registrar_calls += 1;
            if (State.registered) return;
            State.registered = true;
            for (0..16) |_| commands.addObserver(EventId.from(Damage), added, null);
        }
    };
    const system = struct {
        fn call(observers: Observers) void {
            observers.trigger(Damage{ .amount = 1 });
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    world.addObserver(allocator, EventId.from(Damage), Handlers.registrar, null);
    world.addSystem(allocator, "update", system, null);

    world.runSystems(allocator);
    try std.testing.expectEqual(1, State.registrar_calls);
    try std.testing.expectEqual(0, State.added_calls);

    world.runSystems(allocator);
    try std.testing.expectEqual(2, State.registrar_calls);
    try std.testing.expectEqual(16, State.added_calls);
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

    var world = World.init();
    defer world.deinit(allocator);

    const target = world.addEntity(allocator, .{Position{ .x = 5, .y = 0 }});
    _ = world.addEntity(allocator, .{Target{ .entity = target }});

    world.addSystem(allocator, "update", system, null);
    world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 6), State.target_x);
    const position = try world.getEntity(target, &.{Position});
    try std.testing.expectEqual(@as(f32, 6), position[0].x);
}

test "integration: a one-shot system sees resources its plugin's build created through Commands" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const State = struct {
        var seen: ?f32 = null;
    };
    State.seen = null;

    const Plugin = struct {
        pub fn build(_: *@This(), commands: Commands) void {
            commands.addResource(Config, .{ .scale = 2 });
            commands.addOneShotSystem(startup, null);
        }

        fn startup(config: Resource(Config)) void {
            State.seen = config.value.scale;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    world.addPlugin(allocator, Plugin);
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
        pub fn build(_: *@This(), commands: Commands) void {
            commands.addResource(Config, .{ .scale = 3 });
        }
    };
    const Consumer = struct {
        pub fn build(_: *@This(), commands: Commands) void {
            commands.addOneShotSystem(startup, null);
        }

        fn startup(config: Resource(Config)) void {
            State.seen = config.value.scale;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    world.addPlugin(allocator, Consumer);
    world.addPlugin(allocator, Provider);

    world.runSystems(allocator);

    try std.testing.expectEqual(@as(f32, 3), State.seen.?);
}

test "integration: a one-shot system sees entities its plugin's build spawned through Commands" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const State = struct {
        var seen: usize = 0;
    };
    State.seen = 0;

    const Plugin = struct {
        pub fn build(_: *@This(), commands: Commands) void {
            commands.spawn(.{Position{ .x = 1, .y = 1 }});
            commands.addOneShotSystem(startup, null);
        }

        fn startup(positions: Query(&.{Position})) void {
            var it = positions.iterator();
            while (it.next()) |_| State.seen += 1;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    world.addPlugin(allocator, Plugin);
    world.runSystems(allocator);

    try std.testing.expectEqual(1, State.seen);
}

test "integration: a resource Added observer can already read the resource" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const State = struct {
        var seen: ?f32 = null;
    };
    State.seen = null;

    const onAdded = struct {
        fn call(config: Resource(Config), _: Event(ResourceAdded)) void {
            State.seen = config.value.scale;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    world.addObserver(allocator, resource_events.added(Config), onAdded, null);
    world.addResource(allocator, Config, .{ .scale = 3 });

    try std.testing.expectEqual(@as(f32, 3), State.seen.?);
}

test "integration: a resource added through Commands fires Added at the flush" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const State = struct {
        var calls: usize = 0;
    };
    State.calls = 0;

    const onAdded = struct {
        fn call(_: Event(ResourceAdded)) void {
            State.calls += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    world.addObserver(allocator, resource_events.added(Config), onAdded, null);
    Commands.fromWorld(allocator, &world).addResource(Config, .{ .scale = 1 });
    try std.testing.expectEqual(0, State.calls);

    world.command_queue.flush(allocator, &world);

    try std.testing.expectEqual(1, State.calls);
}

test "integration: a resource removed through Commands fires Destroying at the flush" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const State = struct {
        var calls: usize = 0;
    };
    State.calls = 0;

    const onDestroying = struct {
        fn call(_: Event(ResourceDestroying)) void {
            State.calls += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    world.addObserver(allocator, resource_events.destroying(Config), onDestroying, null);
    world.addResource(allocator, Config, .{ .scale = 1 });

    Commands.fromWorld(allocator, &world).removeResource(Config);
    try std.testing.expectEqual(0, State.calls);

    world.command_queue.flush(allocator, &world);

    try std.testing.expectEqual(1, State.calls);
}
