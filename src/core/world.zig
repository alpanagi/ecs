const std = @import("std");

const Archetype = @import("archetype.zig").Archetype;
const ComponentData = @import("component.zig").ComponentData;
const ComponentDescriptor = @import("component.zig").ComponentDescriptor;
const ComponentPointers = @import("component.zig").ComponentPointers;
const componentId = @import("component.zig").componentId;
const componentTypes = @import("component.zig").componentTypes;
const getDeinitFunction = @import("../erasure/deinit.zig").getDeinitFunction;
const Entity = @import("entity.zig").Entity;
const Error = @import("../error.zig").Error;
const Event = @import("../params/views/event.zig").Event;
const EventId = @import("event_id.zig").EventId;
const component_events = @import("lifecycle.zig").component;
const resource_events = @import("lifecycle.zig").resource;
const ComponentAdded = @import("lifecycle.zig").ComponentAdded;
const ComponentDestroying = @import("lifecycle.zig").ComponentDestroying;
const ResourceAdded = @import("lifecycle.zig").ResourceAdded;
const ResourceDestroying = @import("lifecycle.zig").ResourceDestroying;
const Resource = @import("../params/views/resource.zig").Resource;
const panic = @import("../utils.zig").panic;
const panicOom = @import("../utils.zig").panicOom;

const PluginsState = @import("plugins.zig").PluginsState;
const Systems = @import("../params/systems.zig").Systems;
const OneShots = @import("../params/one_shots.zig").OneShots;
const one_shot_group = @import("../params/one_shots.zig").group;
const baseline_groups = @import("../params/systems.zig").baseline_groups;
pub const Observers = @import("../params/observers.zig").Observers;
const buildObserverEntry = @import("../erasure/system_entry.zig").buildObserverEntry;
const buildSystemEntry = @import("../erasure/system_entry.zig").buildSystemEntry;
const SystemEntry = @import("../erasure/system_entry.zig").SystemEntry;
const ObserverEntry = @import("../erasure/system_entry.zig").ObserverEntry;

pub const Entities = @import("../params/entities.zig").Entities;
pub const Resources = @import("../params/resources.zig").Resources;
pub const Query = @import("../params/views/query.zig").Query;

const EntityDescriptor = struct {
    generation: u32,
    archetype: ?u32,
    row: u32,
};

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
            .one_shots = .{},
            .entities = Entities.State.init(),
        };

        for (baseline_groups) |name| world.systems.declareGroup(allocator, name);

        world.systems.addSystemEntry(
            allocator,
            one_shot_group,
            buildSystemEntry(OneShots.run, null),
        );

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

    pub fn addOwnedEntity(self: *World, allocator: std.mem.Allocator, components: anytype) Entity {
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
            self.observers.dispatch(
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

    pub fn addOwnedPlugin(self: *World, allocator: std.mem.Allocator, plugin: anytype) void {
        self.plugins.addPlugin(allocator, self, plugin);
    }

    pub fn addOwnedResource(
        self: *World,
        allocator: std.mem.Allocator,
        comptime T: type,
        value: T,
    ) void {
        const replacing = self.resources.getResource(T) != null;
        if (replacing) {
            self.observers.dispatch(allocator, self, resource_events.destroying(T), &ResourceDestroying{});
        }

        self.resources.addResource(allocator, T, value);

        self.observers.dispatch(allocator, self, resource_events.added(T), &ResourceAdded{});
    }

    pub fn getResource(self: *World, comptime T: type) ?*T {
        return self.resources.getResource(T);
    }

    pub fn removeResource(self: *World, allocator: std.mem.Allocator, comptime T: type) void {
        if (self.resources.getResource(T) == null) return;

        self.observers.dispatch(allocator, self, resource_events.destroying(T), &ResourceDestroying{});
        self.resources.removeResource(allocator, T);
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

    pub fn dispatchOwnedEvent(self: *World, allocator: std.mem.Allocator, event: anytype) void {
        self.observers.dispatchOwnedEvent(allocator, self, event);
    }

    pub fn runSystems(self: *World, allocator: std.mem.Allocator) void {
        self.flushSystemRegistrations(allocator);
        self.resources.flushPending(allocator, self);
        self.entities.flushPending(allocator, self);

        for (self.systems.groups.items) |group| {
            for (group.systems.items) |entry| entry.run(allocator, self);
            self.resources.flushPending(allocator, self);
            self.entities.flushPending(allocator, self);
        }
    }

    fn flushSystemRegistrations(self: *World, allocator: std.mem.Allocator) void {
        self.systems.flushPending(allocator);
        self.observers.flushPending(allocator);
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
        self.observers.dispatch(
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
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init(allocator);

    try world.archetypes.append(allocator, Archetype.init(allocator, &.{ComponentDescriptor.from(Value)}, .{}));

    world.deinit(allocator);
}

test "addOwnedEntity: creates an entity in a new archetype" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.addOwnedEntity(
        allocator,
        .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } },
    );

    try std.testing.expectEqual(Entity{ .id = 0, .generation = 0 }, entity);
    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(0, world.entity_descriptors.items[0].archetype.?);
    try std.testing.expectEqual(0, world.entity_descriptors.items[0].row);
}

test "addOwnedEntity: reuses the archetype for the same component set" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const first = world.addOwnedEntity(
        allocator,
        .{ Position{ .x = 1, .y = 1 }, Velocity{ .dx = 1, .dy = 1 } },
    );
    const second = world.addOwnedEntity(
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

test "addOwnedEntity: stores the entity's component values" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.addOwnedEntity(allocator, .{Position{ .x = 5, .y = 6 }});

    const archetype_id = world.entity_descriptors.items[entity.id].archetype.?;
    const archetype_slot = world.entity_descriptors.items[entity.id].row;

    const position = try getComponents(&world.archetypes.items[archetype_id], archetype_slot, &.{Position});

    try std.testing.expectEqual(Position{ .x = 5, .y = 6 }, position[0].*);
}

test "addOwnedEntity: creates an entity from three component types" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: u32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.addOwnedEntity(allocator, .{
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

test "addOwnedEntity: creates the entity immediately" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.addOwnedEntity(allocator, .{Position{ .x = 1, .y = 2 }});

    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(1, world.archetypes.items[0].entity_count);
}

test "addOwnedEntity: triggers ComponentAdded for each component" {
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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, component_events.added(Position), buildObserverEntry(onPositionAdded, null));
    world.observers.add(allocator, component_events.added(Velocity), buildObserverEntry(onVelocityAdded, null));

    const entity = world.addOwnedEntity(allocator, .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } });

    try std.testing.expectEqual(entity, State.position_entity);
    try std.testing.expectEqual(entity, State.velocity_entity);
}

test "addOwnedEntity: triggers nothing for a component with no observer" {
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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, component_events.added(Position), buildObserverEntry(onPositionAdded, null));

    _ = world.addOwnedEntity(allocator, .{Velocity{ .dx = 1, .dy = 1 }});

    try std.testing.expectEqual(null, State.position_entity);
}

test "addOwnedEntity: triggers lifecycle events for a marker component" {
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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, component_events.added(Player), buildObserverEntry(Handlers.onAdded, null));
    world.observers.add(allocator, component_events.destroying(Player), buildObserverEntry(Handlers.onDestroying, null));

    const entity = world.addOwnedEntity(allocator, .{Player{}});
    try std.testing.expectEqual(1, State.added);
    try std.testing.expectEqual(0, State.destroying);

    world.removeEntity(allocator, entity);
    try std.testing.expectEqual(1, State.destroying);
}

test "removeEntity: does nothing for an out of range entity id" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.removeEntity(allocator, .{ .id = 999, .generation = 0 });

    try std.testing.expectEqual(0, world.entity_descriptors.items.len);
}

test "removeEntity: does nothing for a stale generation" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.addOwnedEntity(allocator, .{Value{ .value = 1 }});

    world.removeEntity(allocator, entity);
    // entity is now stale (generation bumped); removing it again must be a
    // no-op, not a double-free or a second attempt to relocate anything.
    world.removeEntity(allocator, entity);

    try std.testing.expectEqual(entity.generation + 1, world.entity_descriptors.items[entity.id].generation);
}

test "removeEntity: marks the descriptor dead and recycles its id" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.addOwnedEntity(allocator, .{Value{ .value = 1 }});

    world.removeEntity(allocator, entity);

    try std.testing.expectEqual(entity.generation + 1, world.entity_descriptors.items[entity.id].generation);
    try std.testing.expectEqual(null, world.entity_descriptors.items[entity.id].archetype);
    try std.testing.expectEqual(1, world.entity_free_list.items.len);
    try std.testing.expectEqual(entity.id, world.entity_free_list.items[0]);
}

test "removeEntity: fixes up the relocated entity's row" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const first = world.addOwnedEntity(allocator, .{Value{ .value = 1 }});
    _ = world.addOwnedEntity(allocator, .{Value{ .value = 2 }});
    const third = world.addOwnedEntity(allocator, .{Value{ .value = 3 }});

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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const owning = try OwningComponent.init(allocator);
    const entity = world.addOwnedEntity(allocator, .{owning});

    world.removeEntity(allocator, entity);
}

test "removeEntity: bumps the generation before the id is reused" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const first = world.addOwnedEntity(allocator, .{Value{ .value = 1 }});
    world.removeEntity(allocator, first);

    const second = world.addOwnedEntity(allocator, .{Value{ .value = 2 }});

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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, component_events.destroying(Position), buildObserverEntry(onPositionDestroying, null));

    const entity = world.addOwnedEntity(allocator, .{Position{ .x = 1, .y = 2 }});
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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, component_events.destroying(Position), buildObserverEntry(onPositionDestroying, null));

    const entity = world.addOwnedEntity(allocator, .{Position{ .x = 1, .y = 2 }});
    world.removeEntity(allocator, entity);

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, State.observed);
}

test "removeEntity: leaves a marker intact after another entity is swapped out" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const first = world.addOwnedEntity(allocator, .{ Player{}, Position{ .x = 1, .y = 1 } });
    const second = world.addOwnedEntity(allocator, .{ Player{}, Position{ .x = 2, .y = 2 } });

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

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    Systems.fromWorld(std.testing.allocator, &world).addSystem(std.testing.allocator, "update", system, null);

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

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    Systems.fromWorld(std.testing.allocator, &world).addSystem(std.testing.allocator, "update", a, null);
    Systems.fromWorld(std.testing.allocator, &world).addSystem(std.testing.allocator, "update", b, null);

    world.runSystems(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &State.calls);
}

test "addOwnedResource: stores a value that getResource returns" {
    const ClearColor = struct { r: f32, g: f32, b: f32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    world.addOwnedResource(std.testing.allocator, ClearColor, .{ .r = 0, .g = 1, .b = 0 });

    const color = world.getResource(ClearColor).?;
    try std.testing.expectEqual(ClearColor{ .r = 0, .g = 1, .b = 0 }, color.*);
}

test "addOwnedResource: triggers ResourceAdded" {
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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, resource_events.added(Config), buildObserverEntry(onAdded, null));
    world.addOwnedResource(allocator, Config, .{ .scale = 1 });

    try std.testing.expectEqual(1, State.calls);
}

test "addOwnedResource: triggers Destroying for the old value then Added for the new" {
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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, resource_events.added(Config), buildObserverEntry(Handlers.onAdded, null));
    world.observers.add(allocator, resource_events.destroying(Config), buildObserverEntry(Handlers.onDestroying, null));

    world.addOwnedResource(allocator, Config, .{ .scale = 1 });
    world.addOwnedResource(allocator, Config, .{ .scale = 2 });

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 1 }, State.log[0..State.count]);
    try std.testing.expectEqual(@as(f32, 1), State.scale_at_destroying.?);
    try std.testing.expectEqual(@as(f32, 2), State.scale_at_added.?);
}

test "addOwnedResource: does not trigger component events for the same type" {
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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, resource_events.added(Shared), buildObserverEntry(Handlers.onResource, null));
    world.observers.add(allocator, component_events.added(Shared), buildObserverEntry(Handlers.onComponent, null));

    _ = world.addOwnedEntity(allocator, .{Shared{ .value = 1 }});
    try std.testing.expectEqual(1, State.component_added);
    try std.testing.expectEqual(0, State.resource_added);

    world.addOwnedResource(allocator, Shared, .{ .value = 2 });
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

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    world.addOwnedResource(std.testing.allocator, Tracked, .{});
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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, resource_events.destroying(Config), buildObserverEntry(onDestroying, null));
    world.addOwnedResource(allocator, Config, .{ .scale = 5 });
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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, resource_events.destroying(Config), buildObserverEntry(onDestroying, null));
    world.removeResource(allocator, Config);

    try std.testing.expectEqual(0, State.calls);
}

test "getEntity: returns pointers to the requested components" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.addOwnedEntity(
        allocator,
        .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } },
    );

    const position, const velocity = try world.getEntity(entity, &.{ Position, Velocity });

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position.*);
    try std.testing.expectEqual(Velocity{ .dx = 3, .dy = 4 }, velocity.*);
}

test "getEntity: returns InvalidEntity for an out of range entity id" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    try std.testing.expectError(
        Error.InvalidEntity,
        world.getEntity(.{ .id = 999, .generation = 0 }, &.{}),
    );
}

test "getEntity: returns InvalidEntity for a stale generation" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.addOwnedEntity(allocator, .{Value{ .value = 1 }});
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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.addOwnedEntity(allocator, .{Position{ .x = 1, .y = 2 }});

    try std.testing.expectError(
        Error.UnknownComponent,
        world.getEntity(entity, &.{Velocity}),
    );
}

test "getEntity: returns UnknownComponent for a marker the entity lacks" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.addOwnedEntity(allocator, .{Position{ .x = 1, .y = 2 }});

    try std.testing.expectError(
        Error.UnknownComponent,
        world.getEntity(entity, &.{ Player, Position }),
    );
}

test "dispatchOwnedEvent: runs an observer registered through addObserver" {
    const Damage = struct { amount: u32 };
    const State = struct {
        var seen: u32 = 0;
    };
    const onDamage = struct {
        fn call(event: Event(Damage)) void {
            State.seen = event.value.amount;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    world.observers.add(std.testing.allocator, EventId.from(Damage), buildObserverEntry(onDamage, null));
    world.dispatchOwnedEvent(std.testing.allocator, Damage{ .amount = 7 });

    try std.testing.expectEqual(7, State.seen);
}

test "dispatchOwnedEvent: dispatches synchronously through Observers" {
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
            observers.dispatchOwnedEvent(allocator, Damage{ .amount = 7 });
            State.ran_before_system_returned = State.seen == 7;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, EventId.from(Damage), buildObserverEntry(onDamage, null));
    Systems.fromWorld(allocator, &world).addSystem(allocator, "update", system, null);

    world.runSystems(allocator);

    try std.testing.expectEqual(7, State.seen);
    try std.testing.expect(State.ran_before_system_returned);
}

test "dispatchOwnedEvent: deinits the event once after every observer has seen it" {
    const allocator = std.testing.allocator;

    const State = struct {
        var deinits: usize = 0;
        var first: usize = 0;
        var second: usize = 0;
    };
    const Message = struct {
        text: []u8,

        pub fn deinit(self: *@This(), event_allocator: std.mem.Allocator) void {
            State.deinits += 1;
            event_allocator.free(self.text);
        }
    };
    State.deinits = 0;
    State.first = 0;
    State.second = 0;

    const onFirst = struct {
        fn call(event: Event(Message)) void {
            State.first = event.value.text.len;
        }
    }.call;
    const onSecond = struct {
        fn call(event: Event(Message)) void {
            State.second = event.value.text.len;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, EventId.from(Message), buildObserverEntry(onFirst, null));
    world.observers.add(allocator, EventId.from(Message), buildObserverEntry(onSecond, null));

    world.dispatchOwnedEvent(allocator, Message{ .text = try allocator.alloc(u8, 4) });

    try std.testing.expectEqual(4, State.first);
    try std.testing.expectEqual(4, State.second);
    try std.testing.expectEqual(1, State.deinits);
}

test "dispatchOwnedEvent: deinits an event that no observer is listening for" {
    const allocator = std.testing.allocator;

    const State = struct {
        var deinits: usize = 0;
    };
    const Message = struct {
        text: []u8,

        pub fn deinit(self: *@This(), event_allocator: std.mem.Allocator) void {
            State.deinits += 1;
            event_allocator.free(self.text);
        }
    };
    State.deinits = 0;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.dispatchOwnedEvent(allocator, Message{ .text = try allocator.alloc(u8, 4) });

    try std.testing.expectEqual(1, State.deinits);
}

test "dispatchOwnedEvent: leaves an event without deinit untouched" {
    const allocator = std.testing.allocator;

    const Message = struct { text: []u8 };

    const State = struct {
        var seen: usize = 0;
    };
    State.seen = 0;

    const onMessage = struct {
        fn call(event: Event(Message)) void {
            State.seen = event.value.text.len;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, EventId.from(Message), buildObserverEntry(onMessage, null));

    const text = try allocator.alloc(u8, 4);
    defer allocator.free(text);

    world.dispatchOwnedEvent(allocator, Message{ .text = text });

    try std.testing.expectEqual(4, State.seen);
}

test "dispatchOwnedEvent: deinits both events when an observer dispatches another" {
    const allocator = std.testing.allocator;

    const State = struct {
        var order: [2]u8 = .{ 0, 0 };
        var deinits: usize = 0;
    };
    State.order = .{ 0, 0 };
    State.deinits = 0;

    const Inner = struct {
        text: []u8,

        pub fn deinit(self: *@This(), event_allocator: std.mem.Allocator) void {
            State.order[State.deinits] = 'i';
            State.deinits += 1;
            event_allocator.free(self.text);
        }
    };
    const Outer = struct {
        text: []u8,

        pub fn deinit(self: *@This(), event_allocator: std.mem.Allocator) void {
            State.order[State.deinits] = 'o';
            State.deinits += 1;
            event_allocator.free(self.text);
        }
    };

    const onOuter = struct {
        fn call(observers: Observers, inner: std.mem.Allocator, _: Event(Outer)) void {
            const text = inner.alloc(u8, 8) catch panicOom("onOuter");
            observers.dispatchOwnedEvent(inner, Inner{ .text = text });
        }
    }.call;
    const onInner = struct {
        fn call(_: Event(Inner)) void {}
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, EventId.from(Outer), buildObserverEntry(onOuter, null));
    world.observers.add(allocator, EventId.from(Inner), buildObserverEntry(onInner, null));

    world.dispatchOwnedEvent(allocator, Outer{ .text = try allocator.alloc(u8, 4) });

    try std.testing.expectEqual(2, State.deinits);
    try std.testing.expectEqual([2]u8{ 'i', 'o' }, State.order);
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

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    OneShots.fromWorld(std.testing.allocator, &world).addSystem(std.testing.allocator, system, null);
    world.runSystems(std.testing.allocator);
    world.runSystems(std.testing.allocator);

    try std.testing.expectEqual(1, State.calls);
}

test "runSystems: flushes commands queued by a system after each group" {
    const Position = struct { x: f32, y: f32 };

    const system = struct {
        fn call(entities: Entities, allocator: std.mem.Allocator) void {
            entities.spawnOwned(allocator, .{Position{ .x = 1, .y = 2 }});
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    Systems.fromWorld(std.testing.allocator, &world).addSystem(std.testing.allocator, "update", system, null);
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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Systems.fromWorld(allocator, &world).addSystem(allocator, "update", system, null);
    try std.testing.expectEqual(0, world.systems.findGroup("update").?.systems.items.len);

    world.flushSystemRegistrations(allocator);

    try std.testing.expectEqual(1, world.systems.findGroup("update").?.systems.items.len);
    try std.testing.expectEqual(0, State.calls);
}

test "findOrCreateArchetype: creates an archetype for an unseen component set" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const index = world.findOrCreateArchetype(allocator, &.{ ComponentDescriptor.from(Position), ComponentDescriptor.from(Velocity) });

    try std.testing.expectEqual(0, index);
    try std.testing.expectEqual(1, world.archetypes.items.len);
}

test "findOrCreateArchetype: returns the existing archetype for a known component set" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
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

    var world = World.init(allocator);
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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.addOwnedEntity(allocator, .{Position{ .x = 1, .y = 1 }});
    _ = world.addOwnedEntity(allocator, .{ Player{}, Position{ .x = 2, .y = 2 } });
    _ = world.addOwnedEntity(allocator, .{ Frozen{}, Position{ .x = 3, .y = 3 } });

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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.addOwnedEntity(allocator, .{ Player{}, Position{ .x = 1, .y = 1 } });
    _ = world.addOwnedEntity(allocator, .{ Player{}, Position{ .x = 2, .y = 2 } });
    _ = world.addOwnedEntity(allocator, .{ Player{}, Position{ .x = 3, .y = 3 } });

    try std.testing.expectEqual(1, world.archetypes.items.len);

    var it = world.query(&.{ Player, Position }).iterator();
    var matched: usize = 0;
    while (it.next()) |_| matched += 1;

    try std.testing.expectEqual(3, matched);
}

test "reserveEntityId: returns increasing ids when the free list is empty" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    // Simulate an already-allocated, now-dead slot at index 0.
    try world.entity_descriptors.append(allocator, .{ .generation = 1, .archetype = null, .row = 0 });
    try world.entity_free_list.append(allocator, 0);

    const index = world.reserveEntityId(allocator);

    try std.testing.expectEqual(0, index);
    try std.testing.expectEqual(1, world.entity_descriptors.items.len);
}

test "integration: a plugin's build can register an observer through Entities" {
    const Damage = struct { amount: u32 };
    const Plugin = struct {
        total: u32 = 0,

        pub fn build(self: *@This(), observers: Observers, allocator: std.mem.Allocator) void {
            observers.addObserver(allocator, EventId.from(Damage), onDamage, self);
        }

        fn onDamage(self: *@This(), event: Event(Damage)) void {
            self.total += event.value.amount;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    world.addOwnedPlugin(std.testing.allocator, Plugin{});
    world.flushSystemRegistrations(std.testing.allocator);
    world.dispatchOwnedEvent(std.testing.allocator, Damage{ .amount = 5 });

    const entry = world.observers.observers.values()[0].items[0];
    const plugin: *Plugin = @ptrCast(@alignCast(entry.plugin_function.plugin));
    try std.testing.expectEqual(5, plugin.total);
}
