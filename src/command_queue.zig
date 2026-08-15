const std = @import("std");

const World = @import("world.zig").World;
const Entity = @import("entity.zig").Entity;
const panicOom = @import("util.zig").panicOom;

pub const ValueFunctions = struct {
    apply: *const fn (*anyopaque, *World, std.mem.Allocator) void,
    deinit: *const fn (std.mem.Allocator, *anyopaque) void,
    destroy: *const fn (std.mem.Allocator, *anyopaque) void,
};

pub const RemoveEntityFunction = *const fn (*World, std.mem.Allocator, Entity) void;
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
                .spawn => |spawn_command| {
                    spawn_command.functions.deinit(allocator, spawn_command.data);
                    spawn_command.functions.destroy(allocator, spawn_command.data);
                },
                .despawn => {},
                .add_resource => |add_command| {
                    add_command.functions.deinit(allocator, add_command.data);
                    add_command.functions.destroy(allocator, add_command.data);
                },
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
    ) void {
        const Components = @TypeOf(components);

        const data = allocator.create(Components) catch panicOom("CommandQueue.spawn");
        data.* = components;

        self.commands.pushBack(allocator, .{ .spawn = .{
            .data = data,
            .functions = functions,
        } }) catch panicOom("CommandQueue.spawn");
    }

    pub fn despawn(
        self: *CommandQueue,
        allocator: std.mem.Allocator,
        entity: Entity,
        remove: RemoveEntityFunction,
    ) void {
        self.commands.pushBack(allocator, .{ .despawn = .{
            .entity = entity,
            .remove = remove,
        } }) catch panicOom("CommandQueue.despawn");
    }

    pub fn addResource(
        self: *CommandQueue,
        allocator: std.mem.Allocator,
        value: anytype,
        functions: ValueFunctions,
    ) void {
        const Value = @TypeOf(value);

        const data = allocator.create(Value) catch panicOom("CommandQueue.addResource");
        data.* = value;

        self.commands.pushBack(allocator, .{ .add_resource = .{
            .data = data,
            .functions = functions,
        } }) catch panicOom("CommandQueue.addResource");
    }

    pub fn removeResource(
        self: *CommandQueue,
        allocator: std.mem.Allocator,
        remove: RemoveResourceFunction,
    ) void {
        self.commands.pushBack(allocator, .{ .remove_resource = .{ .remove = remove } }) catch
            panicOom("CommandQueue.removeResource");
    }

    pub fn flush(self: *CommandQueue, allocator: std.mem.Allocator, world: *World) void {
        while (self.commands.popFront()) |command| {
            switch (command) {
                .spawn => |spawn_command| {
                    spawn_command.functions.apply(spawn_command.data, world, allocator);
                    spawn_command.functions.destroy(allocator, spawn_command.data);
                },
                .despawn => |despawn_command| despawn_command.remove(world, allocator, despawn_command.entity),
                .add_resource => |add_command| {
                    add_command.functions.apply(add_command.data, world, allocator);
                    add_command.functions.destroy(allocator, add_command.data);
                },
                .remove_resource => |remove_command| remove_command.remove(world, allocator),
            }
        }
    }
};

test "deinit: frees unflushed spawn commands without applying them" {
    const allocator = std.testing.allocator;

    const State = struct {
        var applied: bool = false;
    };

    var queue = CommandQueue.init();
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

    var queue = CommandQueue.init();

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

    var world = World.init();
    defer world.deinit(allocator);

    var queue = CommandQueue.init();
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

    queue.flush(allocator, &world);

    try std.testing.expectEqual(42, State.applied_value);
}

test "despawn: defers invoking the provided function until flush" {
    const allocator = std.testing.allocator;

    const State = struct {
        var removed: ?Entity = null;
    };
    const removeEntity = struct {
        fn call(_: *World, _: std.mem.Allocator, entity: Entity) void {
            State.removed = entity;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    var queue = CommandQueue.init();
    defer queue.deinit(allocator);

    const entity = Entity{ .id = 3, .generation = 0 };
    queue.despawn(allocator, entity, removeEntity);
    try std.testing.expectEqual(null, State.removed);

    queue.flush(allocator, &world);

    try std.testing.expectEqual(entity, State.removed);
}

test "addResource: defers applying its command until flush" {
    const allocator = std.testing.allocator;

    const State = struct {
        var applied_value: u32 = 0;
    };
    State.applied_value = 0;

    var world = World.init();
    defer world.deinit(allocator);

    var queue = CommandQueue.init();
    defer queue.deinit(allocator);

    queue.addResource(allocator, @as(u32, 7), .{
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

    queue.flush(allocator, &world);

    try std.testing.expectEqual(7, State.applied_value);
}

test "removeResource: defers invoking the provided function until flush" {
    const allocator = std.testing.allocator;

    const State = struct {
        var removed: bool = false;
    };
    State.removed = false;

    const removeResource = struct {
        fn call(_: *World, _: std.mem.Allocator) void {
            State.removed = true;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    var queue = CommandQueue.init();
    defer queue.deinit(allocator);

    queue.removeResource(allocator, removeResource);
    try std.testing.expectEqual(false, State.removed);

    queue.flush(allocator, &world);

    try std.testing.expectEqual(true, State.removed);
}

test "flush: applies commands in the order they were enqueued" {
    const allocator = std.testing.allocator;

    const State = struct {
        var calls: [2]u8 = undefined;
        var count: usize = 0;
    };
    const removeEntity = struct {
        fn call(_: *World, _: std.mem.Allocator, _: Entity) void {
            State.calls[State.count] = 2;
            State.count += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(allocator);

    var queue = CommandQueue.init();
    defer queue.deinit(allocator);

    queue.spawn(allocator, @as(u32, 1), .{
        .apply = struct {
            fn call(_: *anyopaque, _: *World, _: std.mem.Allocator) void {
                State.calls[State.count] = 1;
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
    });
    queue.despawn(allocator, Entity{ .id = 0, .generation = 0 }, removeEntity);

    queue.flush(allocator, &world);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &State.calls);
}

test "flush: destroys an applied command without running its deinit" {
    const allocator = std.testing.allocator;

    const State = struct {
        var deinit_calls: usize = 0;
    };
    State.deinit_calls = 0;

    var world = World.init();
    defer world.deinit(allocator);

    var queue = CommandQueue.init();
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

    queue.flush(allocator, &world);

    try std.testing.expectEqual(0, State.deinit_calls);
}
