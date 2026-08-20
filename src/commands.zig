const std = @import("std");

const Entity = @import("entity.zig").Entity;
const componentTypes = @import("component.zig").componentTypes;
const getDeinitFunction = @import("deinit.zig").getDeinitFunction;
const getDestroyFunction = @import("deinit.zig").getDestroyFunction;
const World = @import("world.zig").World;
const Resource = @import("resource.zig").Resource;
const ValueFunctions = @import("command_queue.zig").ValueFunctions;
const RemoveResourceFunction = @import("command_queue.zig").RemoveResourceFunction;
const buildSystemEntry = @import("system_entry.zig").buildSystemEntry;
const buildObserverEntry = @import("system_entry.zig").buildObserverEntry;
const EventId = @import("event.zig").EventId;
const Event = @import("event.zig").Event;
const hashBytes = @import("hash.zig").hashBytes;

pub const Commands = struct {
    world: *World,
    allocator: std.mem.Allocator,

    pub fn fromWorld(allocator: std.mem.Allocator, world: *World) Commands {
        return .{ .world = world, .allocator = allocator };
    }

    pub fn spawnOwned(self: Commands, components: anytype) void {
        const Values = @Tuple(componentTypes(@TypeOf(components)));
        const values: Values = components;

        self.world.command_queue.spawn(self.allocator, values, spawnFunctions(Values));
    }

    pub fn despawn(self: Commands, entity: Entity) void {
        self.world.command_queue.despawn(self.allocator, entity, World.removeEntity);
    }

    pub fn addOwnedResource(self: Commands, comptime T: type, value: T) void {
        self.world.command_queue.addResource(self.allocator, value, addResourceFunctions(T));
    }

    pub fn removeResource(self: Commands, comptime T: type) void {
        self.world.command_queue.removeResource(self.allocator, removeResourceFunction(T));
    }

    pub fn addSystem(
        self: Commands,
        group: []const u8,
        comptime function: anytype,
        plugin: anytype,
    ) void {
        self.world.registration_queue.addSystem(
            self.allocator,
            hashBytes(group),
            buildSystemEntry(function, plugin),
        );
    }

    pub fn addOneShotSystem(
        self: Commands,
        comptime function: anytype,
        plugin: anytype,
    ) void {
        self.world.registration_queue.addOneShotSystem(
            self.allocator,
            buildSystemEntry(function, plugin),
        );
    }

    pub fn addObserver(
        self: Commands,
        event_id: EventId,
        comptime function: anytype,
        plugin: anytype,
    ) void {
        self.world.registration_queue.addObserver(
            self.allocator,
            event_id,
            buildObserverEntry(function, plugin),
        );
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

fn addResourceFunctions(comptime T: type) ValueFunctions {
    return .{
        .apply = struct {
            fn call(data: *anyopaque, world: *World, allocator: std.mem.Allocator) void {
                const typed: *T = @ptrCast(@alignCast(data));
                world.addOwnedResource(allocator, T, typed.*);
            }
        }.call,
        .deinit = getDeinitFunction(T),
        .destroy = getDestroyFunction(T),
    };
}

fn removeResourceFunction(comptime T: type) RemoveResourceFunction {
    return struct {
        fn call(world: *World, allocator: std.mem.Allocator) void {
            world.removeResource(allocator, T);
        }
    }.call;
}

test "spawnOwned: accepts a tuple of only marker components" {
    const allocator = std.testing.allocator;

    const Player = struct {};

    var world = World.init();
    defer world.deinit(allocator);

    Commands.fromWorld(allocator, &world).spawnOwned(.{Player{}});
    world.command_queue.flush(allocator, &world);

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

    var world = World.init();
    defer world.deinit(allocator);

    Commands.fromWorld(allocator, &world).spawnOwned(.{Owning{ .buffer = try allocator.alloc(u8, 8) }});
}

test "spawnOwned: defers entity creation until the queue is flushed" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    const commands = Commands.fromWorld(allocator, &world);

    commands.spawnOwned(.{Position{ .x = 1, .y = 2 }});
    try std.testing.expectEqual(0, world.archetypes.items.len);

    world.command_queue.flush(allocator, &world);

    try std.testing.expectEqual(1, world.archetypes.items.len);
}

test "despawn: defers entity removal until the queue is flushed" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var world = World.init();
    defer world.deinit(allocator);

    const entity = world.addOwnedEntity(allocator, .{Value{ .value = 1 }});

    const commands = Commands.fromWorld(allocator, &world);

    commands.despawn(entity);
    try std.testing.expectEqual(0, world.entity_free_list.items.len);

    world.command_queue.flush(allocator, &world);

    try std.testing.expectEqual(1, world.entity_free_list.items.len);
}

test "addOwnedResource: runs the resource's deinit when the queue is dropped unflushed" {
    const allocator = std.testing.allocator;

    const Owning = struct {
        buffer: []u8,

        pub fn deinit(self: *@This(), inner: std.mem.Allocator) void {
            inner.free(self.buffer);
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    Commands.fromWorld(allocator, &world).addOwnedResource(Owning, .{ .buffer = try allocator.alloc(u8, 16) });
}

test "addOwnedResource: defers registration until the queue is flushed" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    var world = World.init();
    defer world.deinit(allocator);

    Commands.fromWorld(allocator, &world).addOwnedResource(Config, .{ .scale = 2 });
    try std.testing.expectEqual(null, world.getResource(Config));

    world.command_queue.flush(allocator, &world);

    try std.testing.expectEqual(@as(f32, 2), world.getResource(Config).?.scale);
}

test "removeResource: defers removal until the queue is flushed" {
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

    world.addOwnedResource(allocator, Tracked, .{});

    Commands.fromWorld(allocator, &world).removeResource(Tracked);
    try std.testing.expectEqual(0, State.deinits);
    try std.testing.expect(world.getResource(Tracked) != null);

    world.command_queue.flush(allocator, &world);

    try std.testing.expectEqual(1, State.deinits);
    try std.testing.expectEqual(null, world.getResource(Tracked));
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

    var world = World.init();
    defer world.deinit(allocator);

    Commands.fromWorld(allocator, &world).addSystem("update", system, null);
    try std.testing.expectEqual(0, world.system_registry.groups.count());

    world.runSystems(allocator);

    try std.testing.expectEqual(1, world.system_registry.groups.count());
    try std.testing.expectEqual(1, State.calls);
}

test "addOneShotSystem: defers registration until the queue is flushed" {
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

    Commands.fromWorld(allocator, &world).addOneShotSystem(system, null);
    try std.testing.expectEqual(0, State.calls);

    world.runSystems(allocator);
    try std.testing.expectEqual(1, State.calls);

    world.runSystems(allocator);
    try std.testing.expectEqual(1, State.calls);
}

test "addObserver: defers registration until the queue is flushed" {
    const allocator = std.testing.allocator;

    const Damage = struct { amount: u32 };
    const State = struct {
        var seen: u32 = 0;
    };
    State.seen = 0;

    const observer = struct {
        fn call(event: Event(Damage)) void {
            State.seen = event.value.amount;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    Commands.fromWorld(allocator, &world).addObserver(EventId.from(Damage), observer, null);

    world.dispatchOwnedEvent(allocator, Damage{ .amount = 3 });
    try std.testing.expectEqual(0, State.seen);

    world.runSystems(allocator);
    world.dispatchOwnedEvent(allocator, Damage{ .amount = 5 });

    try std.testing.expectEqual(5, State.seen);
}
