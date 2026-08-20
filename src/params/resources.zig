const std = @import("std");

const World = @import("../core/world.zig").World;
const ValueFunctions = @import("../erasure/value.zig").ValueFunctions;
const hash = @import("../erasure/hash.zig").hash;
const DeinitFunction = @import("../erasure/deinit.zig").DeinitFunction;
const DestroyFunction = @import("../erasure/deinit.zig").DestroyFunction;
const getDeinitFunction = @import("../erasure/deinit.zig").getDeinitFunction;
const getDestroyFunction = @import("../erasure/deinit.zig").getDestroyFunction;
const util = @import("../utils.zig");

pub const Resources = struct {
    pub const State = ResourcesState;

    state: *State,

    pub fn fromWorld(_: std.mem.Allocator, world: *World) Resources {
        return .{ .state = &world.resources };
    }

    pub fn addOwned(
        self: Resources,
        allocator: std.mem.Allocator,
        comptime T: type,
        value: T,
    ) void {
        self.state.queueAdd(allocator, value, addFunctions(T));
    }

    pub fn remove(self: Resources, allocator: std.mem.Allocator, comptime T: type) void {
        self.state.queueRemove(allocator, removeFunction(T));
    }
};

pub const RemoveFunction = *const fn (*World, std.mem.Allocator) void;

const Pending = union(enum) {
    add: struct {
        data: *anyopaque,
        functions: ValueFunctions,
    },
    remove: RemoveFunction,
};

const ResourcesState = struct {
    resources: std.AutoArrayHashMapUnmanaged(u64, ResourceEntry) = .empty,
    pending: std.Deque(Pending) = .empty,

    pub fn init() ResourcesState {
        return .{};
    }

    pub fn deinit(self: *ResourcesState, allocator: std.mem.Allocator) void {
        for (self.resources.values()) |entry| entry.release(allocator);
        self.resources.deinit(allocator);

        while (self.pending.popFront()) |command| {
            switch (command) {
                .add => |add| {
                    add.functions.deinit(allocator, add.data);
                    add.functions.destroy(allocator, add.data);
                },
                .remove => {},
            }
        }
        self.pending.deinit(allocator);
    }

    pub fn queueAdd(
        self: *ResourcesState,
        allocator: std.mem.Allocator,
        value: anytype,
        functions: ValueFunctions,
    ) void {
        const Value = @TypeOf(value);

        const data = allocator.create(Value) catch util.panicOom("ResourcesState.queueAdd");
        data.* = value;

        self.pending.pushBack(allocator, .{ .add = .{
            .data = data,
            .functions = functions,
        } }) catch util.panicOom("ResourcesState.queueAdd");
    }

    pub fn queueRemove(
        self: *ResourcesState,
        allocator: std.mem.Allocator,
        remove: RemoveFunction,
    ) void {
        self.pending.pushBack(allocator, .{ .remove = remove }) catch
            util.panicOom("ResourcesState.queueRemove");
    }

    pub fn flushPending(self: *ResourcesState, allocator: std.mem.Allocator, world: *World) void {
        while (self.pending.popFront()) |command| {
            switch (command) {
                .add => |add| {
                    add.functions.apply(add.data, world, allocator);
                    add.functions.destroy(allocator, add.data);
                },
                .remove => |remove| remove(world, allocator),
            }
        }
    }

    pub fn addResource(
        self: *ResourcesState,
        allocator: std.mem.Allocator,
        comptime T: type,
        value: T,
    ) void {
        const resource = allocator.create(T) catch util.panicOom("ResourcesState.addResource");
        resource.* = value;

        const gop = self.resources.getOrPut(allocator, hash(T)) catch
            util.panicOom("ResourcesState.addResource");

        if (gop.found_existing) gop.value_ptr.release(allocator);
        gop.value_ptr.* = .{
            .value = resource,
            .deinit = getDeinitFunction(T),
            .destroy = getDestroyFunction(T),
        };
    }

    pub fn getResource(self: *const Resources.State, comptime T: type) ?*T {
        const entry = self.resources.get(hash(T)) orelse return null;
        return @ptrCast(@alignCast(entry.value));
    }

    pub fn removeResource(
        self: *ResourcesState,
        allocator: std.mem.Allocator,
        comptime T: type,
    ) void {
        if (self.resources.fetchSwapRemove(hash(T))) |removed| {
            removed.value.release(allocator);
        }
    }
};

const ResourceEntry = struct {
    value: *anyopaque,
    deinit: DeinitFunction,
    destroy: DestroyFunction,

    fn release(self: ResourceEntry, allocator: std.mem.Allocator) void {
        self.deinit(allocator, self.value);
        self.destroy(allocator, self.value);
    }
};

fn addFunctions(comptime T: type) ValueFunctions {
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

fn removeFunction(comptime T: type) RemoveFunction {
    return struct {
        fn call(world: *World, allocator: std.mem.Allocator) void {
            world.removeResource(allocator, T);
        }
    }.call;
}

test "deinit: calls deinit on every remaining resource" {
    const State = struct {
        var count: usize = 0;
    };
    const A = struct {
        pub fn deinit(_: *@This()) void {
            State.count += 1;
        }
    };
    const B = struct {
        pub fn deinit(_: *@This()) void {
            State.count += 1;
        }
    };

    var registry = ResourcesState.init();
    registry.addResource(std.testing.allocator, A, .{});
    registry.addResource(std.testing.allocator, B, .{});

    registry.deinit(std.testing.allocator);

    try std.testing.expectEqual(2, State.count);
}

test "deinit: frees a resource that owns memory" {
    const Owner = struct {
        buffer: []u8,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
        }
    };

    const allocator = std.testing.allocator;
    var registry = ResourcesState.init();
    registry.addResource(allocator, Owner, .{ .buffer = try allocator.alloc(u8, 16) });

    registry.deinit(allocator);
}

test "addResource: stores a value that getResource returns" {
    const ClearColor = struct { r: f32, g: f32, b: f32 };

    var registry = ResourcesState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addResource(std.testing.allocator, ClearColor, .{ .r = 1, .g = 0, .b = 0 });

    const color = registry.getResource(ClearColor).?;
    try std.testing.expectEqual(ClearColor{ .r = 1, .g = 0, .b = 0 }, color.*);
}

test "addResource: replaces an existing resource of the same type" {
    const Counter = struct { value: u32 };

    var registry = ResourcesState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addResource(std.testing.allocator, Counter, .{ .value = 1 });
    registry.addResource(std.testing.allocator, Counter, .{ .value = 2 });

    try std.testing.expectEqual(1, registry.resources.count());
    try std.testing.expectEqual(2, registry.getResource(Counter).?.value);
}

test "addResource: calls the old value's deinit when replacing it" {
    const State = struct {
        var count: usize = 0;
    };
    const Tracked = struct {
        pub fn deinit(_: *@This()) void {
            State.count += 1;
        }
    };

    var registry = ResourcesState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addResource(std.testing.allocator, Tracked, .{});
    registry.addResource(std.testing.allocator, Tracked, .{});

    try std.testing.expectEqual(1, State.count);
}

test "addResource: stores a resource that declares no deinit" {
    const Config = struct { title: []const u8 };

    var registry = ResourcesState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addResource(std.testing.allocator, Config, .{ .title = "game" });

    try std.testing.expectEqualStrings("game", registry.getResource(Config).?.title);
}

test "getResource: returns null when the resource was never added" {
    const ClearColor = struct { r: f32, g: f32, b: f32 };

    var registry = ResourcesState.init();
    defer registry.deinit(std.testing.allocator);

    try std.testing.expectEqual(null, registry.getResource(ClearColor));
}

test "getResource: returns a pointer that mutates the stored value in place" {
    const Counter = struct { value: u32 };

    var registry = ResourcesState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addResource(std.testing.allocator, Counter, .{ .value = 0 });

    registry.getResource(Counter).?.value += 1;
    registry.getResource(Counter).?.value += 1;

    try std.testing.expectEqual(2, registry.getResource(Counter).?.value);
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

    var registry = ResourcesState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addResource(std.testing.allocator, Tracked, .{});
    registry.removeResource(std.testing.allocator, Tracked);

    try std.testing.expectEqual(1, State.count);
    try std.testing.expectEqual(null, registry.getResource(Tracked));
}

test "removeResource: does nothing when the resource was never added" {
    const Tracked = struct {};

    var registry = ResourcesState.init();
    defer registry.deinit(std.testing.allocator);

    registry.removeResource(std.testing.allocator, Tracked);
}

test "addOwnedResource: runs the resource's deinit when the queue is dropped unflushed" {
    const allocator = std.testing.allocator;

    const Owning = struct {
        buffer: []u8,

        pub fn deinit(self: *@This(), inner: std.mem.Allocator) void {
            inner.free(self.buffer);
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Resources.fromWorld(allocator, &world).addOwned(allocator, Owning, .{ .buffer = try allocator.alloc(u8, 16) });
}

test "addOwnedResource: defers registration until the queue is flushed" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Resources.fromWorld(allocator, &world).addOwned(allocator, Config, .{ .scale = 2 });
    try std.testing.expectEqual(null, world.getResource(Config));

    world.resources.flushPending(allocator, &world);

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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.addOwnedResource(allocator, Tracked, .{});

    Resources.fromWorld(allocator, &world).remove(allocator, Tracked);
    try std.testing.expectEqual(0, State.deinits);
    try std.testing.expect(world.getResource(Tracked) != null);

    world.resources.flushPending(allocator, &world);

    try std.testing.expectEqual(1, State.deinits);
    try std.testing.expectEqual(null, world.getResource(Tracked));
}

test "queueAdd: defers applying its command until flush" {
    const allocator = std.testing.allocator;

    const State = struct {
        var applied_value: u32 = 0;
    };
    State.applied_value = 0;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    var state = Resources.State.init();
    defer state.deinit(allocator);

    state.queueAdd(allocator, @as(u32, 7), .{
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

    state.flushPending(allocator, &world);

    try std.testing.expectEqual(7, State.applied_value);
}

test "queueRemove: defers invoking the provided function until flush" {
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

    var world = World.init(allocator);
    defer world.deinit(allocator);

    var state = Resources.State.init();
    defer state.deinit(allocator);

    state.queueRemove(allocator, removeResource);
    try std.testing.expectEqual(false, State.removed);

    state.flushPending(allocator, &world);

    try std.testing.expectEqual(true, State.removed);
}
