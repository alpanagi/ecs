const component_events = @import("../core/lifecycle.zig").component;
const std = @import("std");

const Archetype = @import("../core/archetype.zig").Archetype;
const ComponentAdded = @import("../core/lifecycle.zig").ComponentAdded;
const ComponentData = @import("../core/component.zig").ComponentData;
const ComponentDescriptor = @import("../core/component.zig").ComponentDescriptor;
const ComponentDestroying = @import("../core/lifecycle.zig").ComponentDestroying;
const Entity = @import("../core/entity.zig").Entity;
const ValueFunctions = @import("../erasure/value.zig").ValueFunctions;
const World = @import("../core/world.zig").World;

const componentTypes = @import("../core/component.zig").componentTypes;
const getDeinitFunction = @import("../erasure/deinit.zig").getDeinitFunction;
const getDestroyFunction = @import("../erasure/deinit.zig").getDestroyFunction;
const panic = @import("../utils.zig").panic;
const panicOom = @import("../utils.zig").panicOom;

const Pending = union(enum) {
    spawn: struct {
        data: *anyopaque,
        functions: ValueFunctions,
    },
    despawn: Entity,
};

pub const Entities = struct {
    pub const State = EntitiesState;

    state: *State,

    pub fn fromWorld(_: std.mem.Allocator, world: *World) Entities {
        return .{ .state = &world.entities };
    }

    pub fn spawnOwned(self: Entities, allocator: std.mem.Allocator, components: anytype) void {
        const Values = @Tuple(componentTypes(@TypeOf(components)));
        const values: Values = components;

        self.state.queue(allocator, values, spawnFunctions(Values));
    }

    pub fn despawn(self: Entities, allocator: std.mem.Allocator, entity: Entity) void {
        self.state.pending.pushBack(allocator, .{ .despawn = entity }) catch
            panicOom("Entities.despawn");
    }
};

const EntitiesState = struct {
    pending: std.Deque(Pending) = .empty,

    pub fn init() EntitiesState {
        return .{};
    }

    pub fn deinit(self: *EntitiesState, allocator: std.mem.Allocator) void {
        while (self.pending.popFront()) |command| {
            switch (command) {
                .spawn => |spawn_command| {
                    spawn_command.functions.deinit(allocator, spawn_command.data);
                    spawn_command.functions.destroy(allocator, spawn_command.data);
                },
                .despawn => {},
            }
        }
        self.pending.deinit(allocator);
    }

    pub fn flushPending(self: *EntitiesState, allocator: std.mem.Allocator, world: *World) void {
        while (self.pending.popFront()) |command| {
            switch (command) {
                .spawn => |spawn_command| {
                    spawn_command.functions.apply(spawn_command.data, world, allocator);
                    spawn_command.functions.destroy(allocator, spawn_command.data);
                },
                .despawn => |entity| self.despawn(world, allocator, entity),
            }
        }
    }

    pub fn spawnOwned(_: *EntitiesState, world: *World, allocator: std.mem.Allocator, components: anytype) Entity {
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

        const archetype_id = findOrCreateArchetype(world, allocator, &descriptors);
        const id = reserveEntityId(world, allocator);

        const entity = Entity{
            .id = id,
            .generation = world.entity_descriptors.items[id].generation,
        };

        const row = world.archetypes.items[archetype_id].addEntity(
            allocator,
            id,
            &component_data,
        ) catch |err| panic("Entities.spawn: the archetype rejected the entity's components: {}", .{err});

        world.entity_descriptors.items[id].archetype = archetype_id;
        world.entity_descriptors.items[id].row = row;

        inline for (types, 0..) |Component, index| {
            world.observers.dispatchEventById(
                allocator,
                world,
                component_events.added(Component),
                &ComponentAdded{ .entity = entity, .component = descriptors[index].id },
            );
        }

        return entity;
    }

    pub fn despawn(_: *EntitiesState, world: *World, allocator: std.mem.Allocator, entity: Entity) void {
        if (entity.id >= world.entity_descriptors.items.len) return;
        if (world.entity_descriptors.items[entity.id].generation != entity.generation) return;

        const archetype_id = world.entity_descriptors.items[entity.id].archetype.?;

        const sized_components = world.archetypes.items[archetype_id].sized_components;
        const marker_component_ids = world.archetypes.items[archetype_id].marker_component_ids;

        for (sized_components) |component| triggerComponentDestroying(world, allocator, entity, component.id);
        for (marker_component_ids) |component_id| triggerComponentDestroying(world, allocator, entity, component_id);

        const row = world.entity_descriptors.items[entity.id].row;

        if (world.archetypes.items[archetype_id].removeEntity(allocator, row)) |relocated_id| {
            world.entity_descriptors.items[relocated_id].row = row;
        }

        world.entity_descriptors.items[entity.id].generation += 1;
        world.entity_descriptors.items[entity.id].archetype = null;

        world.entity_free_list.append(allocator, entity.id) catch panicOom("Entities.despawn");
    }

    fn queue(
        self: *EntitiesState,
        allocator: std.mem.Allocator,
        components: anytype,
        functions: ValueFunctions,
    ) void {
        const Components = @TypeOf(components);

        const data = allocator.create(Components) catch panicOom("EntitiesState.queue");
        data.* = components;

        self.pending.pushBack(allocator, .{ .spawn = .{
            .data = data,
            .functions = functions,
        } }) catch panicOom("EntitiesState.queue");
    }
};

fn spawnFunctions(comptime Components: type) ValueFunctions {
    return .{
        .apply = struct {
            fn call(data: *anyopaque, world: *World, allocator: std.mem.Allocator) void {
                const typed: *Components = @ptrCast(@alignCast(data));
                _ = world.entities.spawnOwned(world, allocator, typed.*);
            }
        }.call,
        .deinit = struct {
            fn call(allocator: std.mem.Allocator, data: *anyopaque) void {
                const typed: *Components = @ptrCast(@alignCast(data));
                inline for (std.meta.fields(Components)) |field| {
                    getDeinitFunction(field.type)(allocator, &@field(typed.*, field.name));
                }
            }
        }.call,
        .destroy = getDestroyFunction(Components),
    };
}

fn findOrCreateArchetype(
    world: *World,
    allocator: std.mem.Allocator,
    components: []const ComponentDescriptor,
) u32 {
    for (world.archetypes.items, 0..) |*archetype, index| {
        if (archetype.sized_components.len + archetype.marker_component_ids.len != components.len) continue;

        const matches = for (components) |component| {
            if (!archetype.hasComponent(component.id)) break false;
        } else true;

        if (matches) return @intCast(index);
    }

    world.archetypes.append(allocator, Archetype.init(allocator, components, .{})) catch
        panicOom("Entities.findOrCreateArchetype");

    return @intCast(world.archetypes.items.len - 1);
}

fn reserveEntityId(world: *World, allocator: std.mem.Allocator) u32 {
    if (world.entity_free_list.pop()) |id| return id;

    world.entity_descriptors.append(allocator, .{
        .generation = 0,
        .archetype = null,
        .row = 0,
    }) catch panicOom("Entities.reserveEntityId");

    return @intCast(world.entity_descriptors.items.len - 1);
}

fn triggerComponentDestroying(
    world: *World,
    allocator: std.mem.Allocator,
    entity: Entity,
    component_id: u64,
) void {
    world.observers.dispatchEventById(
        allocator,
        world,
        component_events.destroyingById(component_id),
        &ComponentDestroying{ .entity = entity, .component = component_id },
    );
}

test "spawnOwned: accepts a tuple of only marker components" {
    const allocator = std.testing.allocator;

    const Player = struct {};

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Entities.fromWorld(allocator, &world).spawnOwned(allocator, .{Player{}});
    world.entities.flushPending(allocator, &world);

    try std.testing.expectEqual(1, world.entity_descriptors.items.len);
    try std.testing.expectEqual(1, world.archetypes.items[0].entity_count);
}

test "spawnOwned: runs the components' deinit when the queue is dropped unflushed" {
    const allocator = std.testing.allocator;

    const Owning = struct {
        buffer: []u8,

        pub fn deinit(self: *@This(), inner: std.mem.Allocator) void {
            inner.free(self.buffer);
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Entities.fromWorld(allocator, &world).spawnOwned(allocator, .{Owning{ .buffer = try allocator.alloc(u8, 8) }});
}

test "spawnOwned: defers entity creation until the queue is flushed" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entities = Entities.fromWorld(allocator, &world);

    entities.spawnOwned(allocator, .{Position{ .x = 1, .y = 2 }});
    try std.testing.expectEqual(0, world.archetypes.items.len);

    world.entities.flushPending(allocator, &world);

    try std.testing.expectEqual(1, world.archetypes.items.len);
}

test "despawn: defers entity removal until the queue is flushed" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.entities.spawnOwned(&world, allocator, .{Value{ .value = 1 }});

    const entities = Entities.fromWorld(allocator, &world);

    entities.despawn(allocator, entity);
    try std.testing.expectEqual(0, world.entity_free_list.items.len);

    world.entities.flushPending(allocator, &world);

    try std.testing.expectEqual(1, world.entity_free_list.items.len);
}

test "Systems.add: defers registration until the queue is flushed" {
    const Systems = @import("systems.zig").Systems;

    const allocator = std.testing.allocator;

    const groupSystemCount = struct {
        fn call(world: *World, name: []const u8) usize {
            for (world.systems.groups.items) |group| {
                if (std.mem.eql(u8, group.name, name)) return group.systems.items.len;
            }
            return 0;
        }
    }.call;

    const TestState = struct {
        var calls: usize = 0;
    };
    TestState.calls = 0;

    const system = struct {
        fn call() void {
            TestState.calls += 1;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Systems.fromWorld(allocator, &world).add(allocator, "update", system, null);
    try std.testing.expectEqual(0, groupSystemCount(&world, "update"));

    world.runSystems(allocator);

    try std.testing.expectEqual(1, groupSystemCount(&world, "update"));
    try std.testing.expectEqual(1, TestState.calls);
}

test "deinit: frees unflushed spawn commands without applying them" {
    const allocator = std.testing.allocator;

    const TestState = struct {
        var applied: bool = false;
    };

    var queue = Entities.State.init();
    queue.queue(allocator, @as(u32, 1), .{
        .apply = struct {
            fn call(_: *anyopaque, _: *World, _: std.mem.Allocator) void {
                TestState.applied = true;
            }
        }.call,
        .deinit = struct {
            fn call(_: std.mem.Allocator, _: *anyopaque) void {}
        }.call,
        .destroy = struct {
            fn call(command_allocator: std.mem.Allocator, data: *anyopaque) void {
                const typed: *u32 = @ptrCast(@alignCast(data));
                command_allocator.destroy(typed);
            }
        }.call,
    });

    queue.deinit(allocator);

    try std.testing.expect(!TestState.applied);
}

test "deinit: runs deinit before destroy on an unflushed command" {
    const allocator = std.testing.allocator;

    const TestState = struct {
        var log: [2]u8 = undefined;
        var count: usize = 0;
    };
    TestState.count = 0;

    var queue = Entities.State.init();

    queue.queue(allocator, @as(u32, 1), .{
        .apply = struct {
            fn call(_: *anyopaque, _: *World, _: std.mem.Allocator) void {}
        }.call,
        .deinit = struct {
            fn call(_: std.mem.Allocator, _: *anyopaque) void {
                TestState.log[TestState.count] = 1;
                TestState.count += 1;
            }
        }.call,
        .destroy = struct {
            fn call(command_allocator: std.mem.Allocator, data: *anyopaque) void {
                TestState.log[TestState.count] = 2;
                TestState.count += 1;

                const typed: *u32 = @ptrCast(@alignCast(data));
                command_allocator.destroy(typed);
            }
        }.call,
    });

    queue.deinit(allocator);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, TestState.log[0..TestState.count]);
}

test "queue: defers applying its command until flush" {
    const allocator = std.testing.allocator;

    const TestState = struct {
        var applied_value: u32 = 0;
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    var queue = Entities.State.init();
    defer queue.deinit(allocator);

    queue.queue(allocator, @as(u32, 42), .{
        .apply = struct {
            fn call(data: *anyopaque, _: *World, _: std.mem.Allocator) void {
                const typed: *u32 = @ptrCast(@alignCast(data));
                TestState.applied_value = typed.*;
            }
        }.call,
        .deinit = struct {
            fn call(_: std.mem.Allocator, _: *anyopaque) void {}
        }.call,
        .destroy = struct {
            fn call(command_allocator: std.mem.Allocator, data: *anyopaque) void {
                const typed: *u32 = @ptrCast(@alignCast(data));
                command_allocator.destroy(typed);
            }
        }.call,
    });
    try std.testing.expectEqual(0, TestState.applied_value);

    queue.flushPending(allocator, &world);

    try std.testing.expectEqual(42, TestState.applied_value);
}

test "despawn: defers invoking the provided function until flush" {
    const Error = @import("../error.zig").Error;
    const Query = @import("views/query.zig").Query;

    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    var queue = Entities.State.init();
    defer queue.deinit(allocator);

    const entity = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 2 }});
    queue.pending.pushBack(allocator, .{ .despawn = entity }) catch unreachable;
    try std.testing.expect(Query(&.{Position}).fromWorld(allocator, &world).get(entity) catch null != null);

    queue.flushPending(allocator, &world);

    try std.testing.expectError(Error.InvalidEntity, Query(&.{Position}).fromWorld(allocator, &world).get(entity));
}

test "flushPending: applies commands in the order they were enqueued" {
    const allocator = std.testing.allocator;

    const TestState = struct {
        var calls: [2]u8 = undefined;
        var count: usize = 0;
    };
    var world = World.init(allocator);
    defer world.deinit(allocator);

    var queue = Entities.State.init();
    defer queue.deinit(allocator);

    const functions = struct {
        fn tagged(comptime tag: u8) ValueFunctions {
            return .{
                .apply = struct {
                    fn call(_: *anyopaque, _: *World, _: std.mem.Allocator) void {
                        TestState.calls[TestState.count] = tag;
                        TestState.count += 1;
                    }
                }.call,
                .deinit = struct {
                    fn call(_: std.mem.Allocator, _: *anyopaque) void {}
                }.call,
                .destroy = struct {
                    fn call(command_allocator: std.mem.Allocator, data: *anyopaque) void {
                        const typed: *u32 = @ptrCast(@alignCast(data));
                        command_allocator.destroy(typed);
                    }
                }.call,
            };
        }
    };

    queue.queue(allocator, @as(u32, 1), functions.tagged(1));
    queue.queue(allocator, @as(u32, 2), functions.tagged(2));

    queue.flushPending(allocator, &world);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &TestState.calls);
}

test "flushPending: destroys an applied command without running its deinit" {
    const allocator = std.testing.allocator;

    const TestState = struct {
        var deinit_calls: usize = 0;
    };
    TestState.deinit_calls = 0;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    var queue = Entities.State.init();
    defer queue.deinit(allocator);

    queue.queue(allocator, @as(u32, 1), .{
        .apply = struct {
            fn call(_: *anyopaque, _: *World, _: std.mem.Allocator) void {}
        }.call,
        .deinit = struct {
            fn call(_: std.mem.Allocator, _: *anyopaque) void {
                TestState.deinit_calls += 1;
            }
        }.call,
        .destroy = struct {
            fn call(command_allocator: std.mem.Allocator, data: *anyopaque) void {
                const typed: *u32 = @ptrCast(@alignCast(data));
                command_allocator.destroy(typed);
            }
        }.call,
    });

    queue.flushPending(allocator, &world);

    try std.testing.expectEqual(0, TestState.deinit_calls);
}

test "findOrCreateArchetype: creates an archetype for an unseen component set" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const index = findOrCreateArchetype(&world, allocator, &.{ ComponentDescriptor.from(Position), ComponentDescriptor.from(Velocity) });

    try std.testing.expectEqual(0, index);
    try std.testing.expectEqual(1, world.archetypes.items.len);
}

test "findOrCreateArchetype: returns the existing archetype for a known component set" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const first_index = findOrCreateArchetype(&world, allocator, &.{ ComponentDescriptor.from(Position), ComponentDescriptor.from(Velocity) });
    const second_index = findOrCreateArchetype(&world, allocator, &.{ ComponentDescriptor.from(Velocity), ComponentDescriptor.from(Position) });

    try std.testing.expectEqual(first_index, second_index);
    try std.testing.expectEqual(1, world.archetypes.items.len);
}

test "findOrCreateArchetype: creates separate archetypes for different component sets" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const first_index = findOrCreateArchetype(&world, allocator, &.{ComponentDescriptor.from(Position)});
    const second_index = findOrCreateArchetype(&world, allocator, &.{ ComponentDescriptor.from(Position), ComponentDescriptor.from(Velocity) });

    try std.testing.expect(first_index != second_index);
    try std.testing.expectEqual(2, world.archetypes.items.len);
}

test "findOrCreateArchetype: keeps archetypes with different marker sets apart" {
    const Query = @import("views/query.zig").Query;

    const allocator = std.testing.allocator;

    const Player = struct {};
    const Frozen = struct {};
    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 1 }});
    _ = world.entities.spawnOwned(&world, allocator, .{ Player{}, Position{ .x = 2, .y = 2 } });
    _ = world.entities.spawnOwned(&world, allocator, .{ Frozen{}, Position{ .x = 3, .y = 3 } });

    try std.testing.expectEqual(3, world.archetypes.items.len);

    const player_position = Query(&.{ Player, Position }).fromWorld(allocator, &world).first().?[1];
    try std.testing.expectEqual(Position{ .x = 2, .y = 2 }, player_position.*);

    const frozen_position = Query(&.{ Frozen, Position }).fromWorld(allocator, &world).first().?[1];
    try std.testing.expectEqual(Position{ .x = 3, .y = 3 }, frozen_position.*);
}

test "findOrCreateArchetype: reuses the archetype for the same marker set" {
    const Query = @import("views/query.zig").Query;

    const allocator = std.testing.allocator;

    const Player = struct {};
    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{ Player{}, Position{ .x = 1, .y = 1 } });
    _ = world.entities.spawnOwned(&world, allocator, .{ Player{}, Position{ .x = 2, .y = 2 } });
    _ = world.entities.spawnOwned(&world, allocator, .{ Player{}, Position{ .x = 3, .y = 3 } });

    try std.testing.expectEqual(1, world.archetypes.items.len);

    var it = Query(&.{ Player, Position }).fromWorld(allocator, &world).iterator();
    var matched: usize = 0;
    while (it.next()) |_| matched += 1;

    try std.testing.expectEqual(3, matched);
}

test "reserveEntityId: returns increasing ids when the free list is empty" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const first = reserveEntityId(&world, allocator);
    const second = reserveEntityId(&world, allocator);

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

    const index = reserveEntityId(&world, allocator);

    try std.testing.expectEqual(0, index);
    try std.testing.expectEqual(1, world.entity_descriptors.items.len);
}

test "spawnOwned: creates an entity in a new archetype" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.entities.spawnOwned(
        &world,
        allocator,
        .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } },
    );

    try std.testing.expectEqual(Entity{ .id = 0, .generation = 0 }, entity);
    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(0, world.entity_descriptors.items[0].archetype.?);
    try std.testing.expectEqual(0, world.entity_descriptors.items[0].row);
}

test "spawnOwned: reuses the archetype for the same component set" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const first = world.entities.spawnOwned(
        &world,
        allocator,
        .{ Position{ .x = 1, .y = 1 }, Velocity{ .dx = 1, .dy = 1 } },
    );
    const second = world.entities.spawnOwned(
        &world,
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

test "spawnOwned: stores the entity's component values" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 5, .y = 6 }});

    const archetype_id = world.entity_descriptors.items[entity.id].archetype.?;
    const archetype_slot = world.entity_descriptors.items[entity.id].row;

    const position = try world.archetypes.items[archetype_id].getComponents(archetype_slot, &.{Position});

    try std.testing.expectEqual(Position{ .x = 5, .y = 6 }, position[0].*);
}

test "spawnOwned: creates an entity from three component types" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: u32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.entities.spawnOwned(&world, allocator, .{
        Position{ .x = 1, .y = 2 },
        Velocity{ .dx = 3, .dy = 4 },
        Health{ .hp = 100 },
    });

    const archetype_id = world.entity_descriptors.items[entity.id].archetype.?;
    const archetype_slot = world.entity_descriptors.items[entity.id].row;

    const position, const velocity, const health = try world.archetypes.items[archetype_id].getComponents(
        archetype_slot,
        &.{ Position, Velocity, Health },
    );

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position.*);
    try std.testing.expectEqual(Velocity{ .dx = 3, .dy = 4 }, velocity.*);
    try std.testing.expectEqual(Health{ .hp = 100 }, health.*);
}

test "spawnOwned: creates the entity immediately" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 2 }});

    try std.testing.expectEqual(1, world.archetypes.items.len);
    try std.testing.expectEqual(1, world.archetypes.items[0].entity_count);
}

test "spawnOwned: triggers ComponentAdded for each component" {
    const Event = @import("views/event.zig").Event;

    const buildObserverEntry = @import("../erasure/system_entry.zig").buildObserverEntry;

    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestState = struct {
        var position_entity: ?Entity = null;
        var velocity_entity: ?Entity = null;
    };
    const onPositionAdded = struct {
        fn call(event: Event(ComponentAdded)) void {
            TestState.position_entity = event.value.entity;
        }
    }.call;
    const onVelocityAdded = struct {
        fn call(event: Event(ComponentAdded)) void {
            TestState.velocity_entity = event.value.entity;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, component_events.added(Position), buildObserverEntry(onPositionAdded, null));
    world.observers.add(allocator, component_events.added(Velocity), buildObserverEntry(onVelocityAdded, null));

    const entity = world.entities.spawnOwned(&world, allocator, .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } });

    try std.testing.expectEqual(entity, TestState.position_entity);
    try std.testing.expectEqual(entity, TestState.velocity_entity);
}

test "spawnOwned: triggers nothing for a component with no observer" {
    const Event = @import("views/event.zig").Event;

    const buildObserverEntry = @import("../erasure/system_entry.zig").buildObserverEntry;

    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestState = struct {
        var position_entity: ?Entity = null;
    };
    const onPositionAdded = struct {
        fn call(event: Event(ComponentAdded)) void {
            TestState.position_entity = event.value.entity;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, component_events.added(Position), buildObserverEntry(onPositionAdded, null));

    _ = world.entities.spawnOwned(&world, allocator, .{Velocity{ .dx = 1, .dy = 1 }});

    try std.testing.expectEqual(null, TestState.position_entity);
}

test "spawnOwned: triggers lifecycle events for a marker component" {
    const Event = @import("views/event.zig").Event;

    const buildObserverEntry = @import("../erasure/system_entry.zig").buildObserverEntry;

    const allocator = std.testing.allocator;

    const Player = struct {};

    const TestState = struct {
        var added: usize = 0;
        var destroying: usize = 0;
    };
    TestState.added = 0;
    TestState.destroying = 0;

    const Handlers = struct {
        fn onAdded(_: Event(ComponentAdded)) void {
            TestState.added += 1;
        }

        fn onDestroying(_: Event(ComponentDestroying)) void {
            TestState.destroying += 1;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, component_events.added(Player), buildObserverEntry(Handlers.onAdded, null));
    world.observers.add(allocator, component_events.destroying(Player), buildObserverEntry(Handlers.onDestroying, null));

    const entity = world.entities.spawnOwned(&world, allocator, .{Player{}});
    try std.testing.expectEqual(1, TestState.added);
    try std.testing.expectEqual(0, TestState.destroying);

    world.entities.despawn(&world, allocator, entity);
    try std.testing.expectEqual(1, TestState.destroying);
}

test "despawn: does nothing for an out of range entity id" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.entities.despawn(&world, allocator, .{ .id = 999, .generation = 0 });

    try std.testing.expectEqual(0, world.entity_descriptors.items.len);
}

test "despawn: does nothing for a stale generation" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.entities.spawnOwned(&world, allocator, .{Value{ .value = 1 }});

    world.entities.despawn(&world, allocator, entity);
    // entity is now stale (generation bumped); removing it again must be a
    // no-op, not a double-free or a second attempt to relocate anything.
    world.entities.despawn(&world, allocator, entity);

    try std.testing.expectEqual(entity.generation + 1, world.entity_descriptors.items[entity.id].generation);
}

test "despawn: marks the descriptor dead and recycles its id" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const entity = world.entities.spawnOwned(&world, allocator, .{Value{ .value = 1 }});

    world.entities.despawn(&world, allocator, entity);

    try std.testing.expectEqual(entity.generation + 1, world.entity_descriptors.items[entity.id].generation);
    try std.testing.expectEqual(null, world.entity_descriptors.items[entity.id].archetype);
    try std.testing.expectEqual(1, world.entity_free_list.items.len);
    try std.testing.expectEqual(entity.id, world.entity_free_list.items[0]);
}

test "despawn: fixes up the relocated entity's row" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const first = world.entities.spawnOwned(&world, allocator, .{Value{ .value = 1 }});
    _ = world.entities.spawnOwned(&world, allocator, .{Value{ .value = 2 }});
    const third = world.entities.spawnOwned(&world, allocator, .{Value{ .value = 3 }});

    world.entities.despawn(&world, allocator, first);

    // third was the last entity in the archetype, so it should have been
    // swapped into first's now-vacated archetype slot.
    try std.testing.expectEqual(0, world.entity_descriptors.items[third.id].row);
}

test "despawn: deinits memory owned by the removed entity's components" {
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
    const entity = world.entities.spawnOwned(&world, allocator, .{owning});

    world.entities.despawn(&world, allocator, entity);
}

test "despawn: bumps the generation before the id is reused" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const first = world.entities.spawnOwned(&world, allocator, .{Value{ .value = 1 }});
    world.entities.despawn(&world, allocator, first);

    const second = world.entities.spawnOwned(&world, allocator, .{Value{ .value = 2 }});

    try std.testing.expectEqual(first.id, second.id);
    try std.testing.expectEqual(first.generation + 1, second.generation);
}

test "despawn: triggers ComponentDestroying for each component" {
    const Event = @import("views/event.zig").Event;

    const buildObserverEntry = @import("../erasure/system_entry.zig").buildObserverEntry;

    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const TestState = struct {
        var destroying_entity: ?Entity = null;
    };
    const onPositionDestroying = struct {
        fn call(event: Event(ComponentDestroying)) void {
            TestState.destroying_entity = event.value.entity;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, component_events.destroying(Position), buildObserverEntry(onPositionDestroying, null));

    const entity = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 2 }});
    world.entities.despawn(&world, allocator, entity);

    try std.testing.expectEqual(entity, TestState.destroying_entity);
}

test "despawn: triggers ComponentDestroying while the component is readable" {
    const Event = @import("views/event.zig").Event;
    const Query = @import("views/query.zig").Query;

    const buildObserverEntry = @import("../erasure/system_entry.zig").buildObserverEntry;

    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const TestState = struct {
        var observed: ?Position = null;
    };
    const onPositionDestroying = struct {
        fn call(positions: Query(&.{Position}), event: Event(ComponentDestroying)) void {
            const components = positions.get(event.value.entity) catch return;
            TestState.observed = components[0].*;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, component_events.destroying(Position), buildObserverEntry(onPositionDestroying, null));

    const entity = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 2 }});
    world.entities.despawn(&world, allocator, entity);

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, TestState.observed);
}

test "despawn: leaves a marker intact after another entity is swapped out" {
    const Query = @import("views/query.zig").Query;

    const allocator = std.testing.allocator;

    const Player = struct {};
    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const first = world.entities.spawnOwned(&world, allocator, .{ Player{}, Position{ .x = 1, .y = 1 } });
    const second = world.entities.spawnOwned(&world, allocator, .{ Player{}, Position{ .x = 2, .y = 2 } });

    world.entities.despawn(&world, allocator, first);

    const position = try Query(&.{ Player, Position }).fromWorld(allocator, &world).get(second);
    try std.testing.expectEqual(Position{ .x = 2, .y = 2 }, position[1].*);
}
