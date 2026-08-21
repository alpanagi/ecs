const std = @import("std");

const Entity = @import("../core/entity.zig").Entity;
const componentTypes = @import("../core/component.zig").componentTypes;
const getDeinitFunction = @import("../erasure/deinit.zig").getDeinitFunction;
const getDestroyFunction = @import("../erasure/deinit.zig").getDestroyFunction;
const Error = @import("../error.zig").Error;
const World = @import("../core/world.zig").World;
const ValueFunctions = @import("../erasure/value.zig").ValueFunctions;
const panicOom = @import("../utils.zig").panicOom;
const Systems = @import("systems.zig").Systems;
const Resource = @import("views/resource.zig").Resource;
const EventId = @import("../core/event_id.zig").EventId;
const Event = @import("views/event.zig").Event;

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

        self.state.spawn(allocator, values, spawnFunctions(Values));
    }

    pub fn despawn(self: Entities, allocator: std.mem.Allocator, entity: Entity) void {
        self.state.despawn(allocator, entity);
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

    pub fn spawn(
        self: *EntitiesState,
        allocator: std.mem.Allocator,
        components: anytype,
        functions: ValueFunctions,
    ) void {
        const Components = @TypeOf(components);

        const data = allocator.create(Components) catch panicOom("EntitiesState.spawn");
        data.* = components;

        self.pending.pushBack(allocator, .{ .spawn = .{
            .data = data,
            .functions = functions,
        } }) catch panicOom("EntitiesState.spawn");
    }

    pub fn despawn(
        self: *EntitiesState,
        allocator: std.mem.Allocator,
        entity: Entity,
    ) void {
        self.pending.pushBack(allocator, .{ .despawn = entity }) catch
            panicOom("EntitiesState.despawn");
    }

    pub fn flushPending(self: *EntitiesState, allocator: std.mem.Allocator, world: *World) void {
        while (self.pending.popFront()) |command| {
            switch (command) {
                .spawn => |spawn_command| {
                    spawn_command.functions.apply(spawn_command.data, world, allocator);
                    spawn_command.functions.destroy(allocator, spawn_command.data);
                },
                .despawn => |entity| world.removeEntity(allocator, entity),
            }
        }
    }
};

fn spawnFunctions(comptime Components: type) ValueFunctions {
    return .{
        .apply = struct {
            fn call(data: *anyopaque, world: *World, allocator: std.mem.Allocator) void {
                const typed: *Components = @ptrCast(@alignCast(data));
                _ = world.addOwnedEntity(allocator, typed.*);
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

    const entity = world.addOwnedEntity(allocator, .{Value{ .value = 1 }});

    const entities = Entities.fromWorld(allocator, &world);

    entities.despawn(allocator, entity);
    try std.testing.expectEqual(0, world.entity_free_list.items.len);

    world.entities.flushPending(allocator, &world);

    try std.testing.expectEqual(1, world.entity_free_list.items.len);
}

test "addSystem: defers registration until the queue is flushed" {
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

    Systems.fromWorld(allocator, &world).add(allocator, "update", system, null);
    try std.testing.expectEqual(0, world.systems.findGroup("update").?.systems.items.len);

    world.runSystems(allocator);

    try std.testing.expectEqual(1, world.systems.findGroup("update").?.systems.items.len);
    try std.testing.expectEqual(1, State.calls);
}

test "deinit: frees unflushed spawn commands without applying them" {
    const allocator = std.testing.allocator;

    const State = struct {
        var applied: bool = false;
    };

    var queue = Entities.State.init();
    queue.spawn(allocator, @as(u32, 1), .{
        .apply = struct {
            fn call(_: *anyopaque, _: *World, _: std.mem.Allocator) void {
                State.applied = true;
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

    try std.testing.expect(!State.applied);
}

test "deinit: runs deinit before destroy on an unflushed command" {
    const allocator = std.testing.allocator;

    const State = struct {
        var log: [2]u8 = undefined;
        var count: usize = 0;
    };
    State.count = 0;

    var queue = Entities.State.init();

    queue.spawn(allocator, @as(u32, 1), .{
        .apply = struct {
            fn call(_: *anyopaque, _: *World, _: std.mem.Allocator) void {}
        }.call,
        .deinit = struct {
            fn call(_: std.mem.Allocator, _: *anyopaque) void {
                State.log[State.count] = 1;
                State.count += 1;
            }
        }.call,
        .destroy = struct {
            fn call(command_allocator: std.mem.Allocator, data: *anyopaque) void {
                State.log[State.count] = 2;
                State.count += 1;

                const typed: *u32 = @ptrCast(@alignCast(data));
                command_allocator.destroy(typed);
            }
        }.call,
    });

    queue.deinit(allocator);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, State.log[0..State.count]);
}

test "spawn: defers applying its command until flush" {
    const allocator = std.testing.allocator;

    const State = struct {
        var applied_value: u32 = 0;
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    var queue = Entities.State.init();
    defer queue.deinit(allocator);

    queue.spawn(allocator, @as(u32, 42), .{
        .apply = struct {
            fn call(data: *anyopaque, _: *World, _: std.mem.Allocator) void {
                const typed: *u32 = @ptrCast(@alignCast(data));
                State.applied_value = typed.*;
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
    try std.testing.expectEqual(0, State.applied_value);

    queue.flushPending(allocator, &world);

    try std.testing.expectEqual(42, State.applied_value);
}

test "despawn: defers invoking the provided function until flush" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    var queue = Entities.State.init();
    defer queue.deinit(allocator);

    const entity = world.addOwnedEntity(allocator, .{Position{ .x = 1, .y = 2 }});
    queue.despawn(allocator, entity);
    try std.testing.expect(world.getEntity(entity, &.{Position}) catch null != null);

    queue.flushPending(allocator, &world);

    try std.testing.expectError(Error.InvalidEntity, world.getEntity(entity, &.{Position}));
}

test "flush: applies commands in the order they were enqueued" {
    const allocator = std.testing.allocator;

    const State = struct {
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
                        State.calls[State.count] = tag;
                        State.count += 1;
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

    queue.spawn(allocator, @as(u32, 1), functions.tagged(1));
    queue.spawn(allocator, @as(u32, 2), functions.tagged(2));

    queue.flushPending(allocator, &world);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &State.calls);
}

test "flush: destroys an applied command without running its deinit" {
    const allocator = std.testing.allocator;

    const State = struct {
        var deinit_calls: usize = 0;
    };
    State.deinit_calls = 0;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    var queue = Entities.State.init();
    defer queue.deinit(allocator);

    queue.spawn(allocator, @as(u32, 1), .{
        .apply = struct {
            fn call(_: *anyopaque, _: *World, _: std.mem.Allocator) void {}
        }.call,
        .deinit = struct {
            fn call(_: std.mem.Allocator, _: *anyopaque) void {
                State.deinit_calls += 1;
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

    try std.testing.expectEqual(0, State.deinit_calls);
}
