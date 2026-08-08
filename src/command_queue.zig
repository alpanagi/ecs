const std = @import("std");

const World = @import("world.zig").World;
const Entity = @import("entity.zig").Entity;

pub const ValueFunctions = struct {
    apply: *const fn (*anyopaque, *World, std.mem.Allocator) anyerror!void,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
};

pub const RemoveEntityFunction = *const fn (*World, std.mem.Allocator, Entity) anyerror!void;
pub const RemoveResourceFunction = *const fn (*World, std.mem.Allocator) void;

const Command = union(enum) {
    spawn: struct {
        data: *anyopaque,
        functions: ValueFunctions,
    },
    despawn: struct {
        entity: Entity,
        remove: RemoveEntityFunction,
    },
    add_resource: struct {
        data: *anyopaque,
        functions: ValueFunctions,
    },
    remove_resource: struct {
        remove: RemoveResourceFunction,
    },
};

pub const CommandQueue = struct {
    commands: std.Deque(Command) = .empty,

    pub fn init() CommandQueue {
        return .{};
    }

    pub fn deinit(self: *CommandQueue, allocator: std.mem.Allocator) void {
        while (self.commands.popFront()) |command| {
            switch (command) {
                .spawn => |spawn_command| spawn_command.functions.destroy(spawn_command.data, allocator),
                .despawn => {},
                .add_resource => |add_command| add_command.functions.destroy(add_command.data, allocator),
                .remove_resource => {},
            }
        }
        self.commands.deinit(allocator);
    }

    pub fn spawn(
        self: *CommandQueue,
        allocator: std.mem.Allocator,
        components: anytype,
        functions: ValueFunctions,
    ) !void {
        const Components = @TypeOf(components);

        const data = try allocator.create(Components);
        errdefer allocator.destroy(data);
        data.* = components;

        try self.commands.pushBack(allocator, .{ .spawn = .{
            .data = data,
            .functions = functions,
        } });
    }

    pub fn despawn(
        self: *CommandQueue,
        allocator: std.mem.Allocator,
        entity: Entity,
        remove: RemoveEntityFunction,
    ) !void {
        try self.commands.pushBack(allocator, .{ .despawn = .{
            .entity = entity,
            .remove = remove,
        } });
    }

    pub fn addResource(
        self: *CommandQueue,
        allocator: std.mem.Allocator,
        value: anytype,
        functions: ValueFunctions,
    ) !void {
        const Value = @TypeOf(value);

        const data = try allocator.create(Value);
        errdefer allocator.destroy(data);
        data.* = value;

        try self.commands.pushBack(allocator, .{ .add_resource = .{
            .data = data,
            .functions = functions,
        } });
    }

    pub fn removeResource(
        self: *CommandQueue,
        allocator: std.mem.Allocator,
        remove: RemoveResourceFunction,
    ) !void {
        try self.commands.pushBack(allocator, .{ .remove_resource = .{ .remove = remove } });
    }

    pub fn flush(self: *CommandQueue, allocator: std.mem.Allocator, world: *World) !void {
        while (self.commands.popFront()) |command| {
            switch (command) {
                .spawn => |spawn_command| {
                    defer spawn_command.functions.destroy(spawn_command.data, allocator);
                    try spawn_command.functions.apply(spawn_command.data, world, allocator);
                },
                .despawn => |despawn_command| try despawn_command.remove(world, allocator, despawn_command.entity),
                .add_resource => |add_command| {
                    defer add_command.functions.destroy(add_command.data, allocator);
                    try add_command.functions.apply(add_command.data, world, allocator);
                },
                .remove_resource => |remove_command| remove_command.remove(world, allocator),
            }
        }
    }
};

test "CommandQueue.spawn defers applying its command until flush" {
    const allocator = std.testing.allocator;

    const State = struct {
        var applied_value: u32 = 0;
    };

    var world = World.init();
    defer world.deinit(allocator);

    var queue = CommandQueue.init();
    defer queue.deinit(allocator);

    try queue.spawn(allocator, @as(u32, 42), .{
        .apply = struct {
            fn call(data: *anyopaque, _: *World, _: std.mem.Allocator) !void {
                const typed: *u32 = @ptrCast(@alignCast(data));
                State.applied_value = typed.*;
            }
        }.call,
        .destroy = struct {
            fn call(data: *anyopaque, command_allocator: std.mem.Allocator) void {
                const typed: *u32 = @ptrCast(@alignCast(data));
                command_allocator.destroy(typed);
            }
        }.call,
    });
    try std.testing.expectEqual(0, State.applied_value);

    try queue.flush(allocator, &world);

    try std.testing.expectEqual(42, State.applied_value);
}

test "CommandQueue.despawn defers invoking the provided function until flush" {
    const allocator = std.testing.allocator;

    const State = struct {
        var removed: ?Entity = null;
    };
    const removeEntity = struct {
        fn call(_: *World, _: std.mem.Allocator, entity: Entity) !void {
            State.removed = entity;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    var queue = CommandQueue.init();
    defer queue.deinit(allocator);

    const entity = Entity{ .id = 3, .generation = 0 };
    try queue.despawn(allocator, entity, removeEntity);
    try std.testing.expectEqual(null, State.removed);

    try queue.flush(allocator, &world);

    try std.testing.expectEqual(entity, State.removed);
}

test "CommandQueue.flush applies commands in the order they were enqueued" {
    const allocator = std.testing.allocator;

    const State = struct {
        var calls: [2]u8 = undefined;
        var count: usize = 0;
    };
    const removeEntity = struct {
        fn call(_: *World, _: std.mem.Allocator, _: Entity) !void {
            State.calls[State.count] = 2;
            State.count += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    var queue = CommandQueue.init();
    defer queue.deinit(allocator);

    try queue.spawn(allocator, @as(u32, 1), .{
        .apply = struct {
            fn call(_: *anyopaque, _: *World, _: std.mem.Allocator) !void {
                State.calls[State.count] = 1;
                State.count += 1;
            }
        }.call,
        .destroy = struct {
            fn call(data: *anyopaque, command_allocator: std.mem.Allocator) void {
                const typed: *u32 = @ptrCast(@alignCast(data));
                command_allocator.destroy(typed);
            }
        }.call,
    });
    try queue.despawn(allocator, Entity{ .id = 0, .generation = 0 }, removeEntity);

    try queue.flush(allocator, &world);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &State.calls);
}

test "CommandQueue.deinit frees unflushed spawn commands without applying them" {
    const allocator = std.testing.allocator;

    const State = struct {
        var applied: bool = false;
    };

    var queue = CommandQueue.init();
    try queue.spawn(allocator, @as(u32, 1), .{
        .apply = struct {
            fn call(_: *anyopaque, _: *World, _: std.mem.Allocator) !void {
                State.applied = true;
            }
        }.call,
        .destroy = struct {
            fn call(data: *anyopaque, command_allocator: std.mem.Allocator) void {
                const typed: *u32 = @ptrCast(@alignCast(data));
                command_allocator.destroy(typed);
            }
        }.call,
    });

    queue.deinit(allocator);

    try std.testing.expect(!State.applied);
}