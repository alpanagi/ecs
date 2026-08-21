const std = @import("std");
const util = @import("../utils.zig");

const DeinitFunction = @import("../erasure/deinit.zig").DeinitFunction;
const DestroyFunction = @import("../erasure/deinit.zig").DestroyFunction;
const ResourceAdded = @import("../events/resource.zig").ResourceAdded;
const ResourceDestroying = @import("../events/resource.zig").ResourceDestroying;
const ValueFunctions = @import("../erasure/value.zig").ValueFunctions;
const World = @import("../core/world.zig").World;

const getDeinitFunction = @import("../erasure/deinit.zig").getDeinitFunction;
const getDestroyFunction = @import("../erasure/deinit.zig").getDestroyFunction;
const panicOom = @import("../utils.zig").panicOom;
const resourceId = @import("../core/resource.zig").resourceId;

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
        self.state.queue(allocator, value, addFunctions(T));
    }

    pub fn remove(self: Resources, allocator: std.mem.Allocator, comptime T: type) void {
        self.state.pending.pushBack(allocator, .{ .remove = removeFunction(T) }) catch
            panicOom("Resources.remove");
    }
};

const RemoveFunction = *const fn (*World, std.mem.Allocator) void;

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
                .add => |queued| {
                    queued.functions.deinit(allocator, queued.data);
                    queued.functions.destroy(allocator, queued.data);
                },
                .remove => {},
            }
        }
        self.pending.deinit(allocator);
    }

    fn queue(
        self: *ResourcesState,
        allocator: std.mem.Allocator,
        value: anytype,
        functions: ValueFunctions,
    ) void {
        const Value = @TypeOf(value);

        const data = allocator.create(Value) catch util.panicOom("ResourcesState.queue");
        data.* = value;

        self.pending.pushBack(allocator, .{ .add = .{
            .data = data,
            .functions = functions,
        } }) catch util.panicOom("ResourcesState.queue");
    }

    pub fn flushPending(self: *ResourcesState, allocator: std.mem.Allocator, world: *World) void {
        while (self.pending.popFront()) |command| {
            switch (command) {
                .add => |queued| {
                    queued.functions.apply(queued.data, world, allocator);
                    queued.functions.destroy(allocator, queued.data);
                },
                .remove => |function| function(world, allocator),
            }
        }
    }

    fn addResource(
        self: *ResourcesState,
        allocator: std.mem.Allocator,
        comptime T: type,
        value: T,
    ) void {
        const resource = allocator.create(T) catch util.panicOom("ResourcesState.addResource");
        resource.* = value;

        const gop = self.resources.getOrPut(allocator, resourceId(T)) catch
            util.panicOom("ResourcesState.addResource");

        if (gop.found_existing) gop.value_ptr.release(allocator);
        gop.value_ptr.* = .{
            .value = resource,
            .deinit = getDeinitFunction(T),
            .destroy = getDestroyFunction(T),
        };
    }

    pub fn get(self: *const ResourcesState, comptime T: type) ?*T {
        const entry = self.resources.get(resourceId(T)) orelse return null;
        return @ptrCast(@alignCast(entry.value));
    }

    pub fn addOwned(
        self: *ResourcesState,
        world: *World,
        allocator: std.mem.Allocator,
        comptime T: type,
        value: T,
    ) void {
        const replacing = self.get(T) != null;
        if (replacing) {
            world.observers.dispatchOwnedEvent(allocator, world, ResourceDestroying{ .resource_id = resourceId(T) });
        }

        self.addResource(allocator, T, value);

        world.observers.dispatchOwnedEvent(allocator, world, ResourceAdded{ .resource_id = resourceId(T) });
    }

    pub fn remove(self: *ResourcesState, world: *World, allocator: std.mem.Allocator, comptime T: type) void {
        if (self.get(T) == null) return;

        world.observers.dispatchOwnedEvent(allocator, world, ResourceDestroying{ .resource_id = resourceId(T) });

        if (self.resources.fetchSwapRemove(resourceId(T))) |removed| {
            removed.value.release(allocator);
        }
    }
};

const Pending = union(enum) {
    add: struct {
        data: *anyopaque,
        functions: ValueFunctions,
    },
    remove: RemoveFunction,
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
                world.resources.addOwned(world, allocator, T, typed.*);
            }
        }.call,
        .deinit = getDeinitFunction(T),
        .destroy = getDestroyFunction(T),
    };
}

fn removeFunction(comptime T: type) RemoveFunction {
    return struct {
        fn call(world: *World, allocator: std.mem.Allocator) void {
            world.resources.remove(world, allocator, T);
        }
    }.call;
}

test "deinit: calls deinit on every remaining resource" {
    const TestState = struct {
        var count: usize = 0;
    };
    const A = struct {
        pub fn deinit(_: *@This()) void {
            TestState.count += 1;
        }
    };
    const B = struct {
        pub fn deinit(_: *@This()) void {
            TestState.count += 1;
        }
    };

    var registry = ResourcesState.init();
    registry.addResource(std.testing.allocator, A, .{});
    registry.addResource(std.testing.allocator, B, .{});

    registry.deinit(std.testing.allocator);

    try std.testing.expectEqual(2, TestState.count);
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

    const color = registry.get(ClearColor).?;
    try std.testing.expectEqual(ClearColor{ .r = 1, .g = 0, .b = 0 }, color.*);
}

test "addResource: replaces an existing resource of the same type" {
    const Counter = struct { value: u32 };

    var registry = ResourcesState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addResource(std.testing.allocator, Counter, .{ .value = 1 });
    registry.addResource(std.testing.allocator, Counter, .{ .value = 2 });

    try std.testing.expectEqual(1, registry.resources.count());
    try std.testing.expectEqual(2, registry.get(Counter).?.value);
}

test "addResource: calls the old value's deinit when replacing it" {
    const TestState = struct {
        var count: usize = 0;
    };
    const Tracked = struct {
        pub fn deinit(_: *@This()) void {
            TestState.count += 1;
        }
    };

    var registry = ResourcesState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addResource(std.testing.allocator, Tracked, .{});
    registry.addResource(std.testing.allocator, Tracked, .{});

    try std.testing.expectEqual(1, TestState.count);
}

test "addResource: stores a resource that declares no deinit" {
    const Config = struct { title: []const u8 };

    var registry = ResourcesState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addResource(std.testing.allocator, Config, .{ .title = "game" });

    try std.testing.expectEqualStrings("game", registry.get(Config).?.title);
}

test "get: returns null when the resource was never added" {
    const ClearColor = struct { r: f32, g: f32, b: f32 };

    var registry = ResourcesState.init();
    defer registry.deinit(std.testing.allocator);

    try std.testing.expectEqual(null, registry.get(ClearColor));
}

test "get: returns a pointer that mutates the stored value in place" {
    const Counter = struct { value: u32 };

    var registry = ResourcesState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addResource(std.testing.allocator, Counter, .{ .value = 0 });

    registry.get(Counter).?.value += 1;
    registry.get(Counter).?.value += 1;

    try std.testing.expectEqual(2, registry.get(Counter).?.value);
}

test "remove: drops the entry and runs its deinit" {
    const TestState = struct {
        var count: usize = 0;
    };
    const Tracked = struct {
        pub fn deinit(_: *@This()) void {
            TestState.count += 1;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    world.resources.addOwned(&world, std.testing.allocator, Tracked, .{});
    world.resources.remove(&world, std.testing.allocator, Tracked);

    try std.testing.expectEqual(1, TestState.count);
    try std.testing.expectEqual(null, world.resources.get(Tracked));
}

test "remove: does nothing when the resource was never added" {
    const Tracked = struct {};

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    world.resources.remove(&world, std.testing.allocator, Tracked);
}

test "addOwned: runs the resource's deinit when the queue is dropped unflushed" {
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

test "addOwned: defers registration until the queue is flushed" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Resources.fromWorld(allocator, &world).addOwned(allocator, Config, .{ .scale = 2 });
    try std.testing.expectEqual(null, world.resources.get(Config));

    world.resources.flushPending(allocator, &world);

    try std.testing.expectEqual(@as(f32, 2), world.resources.get(Config).?.scale);
}

test "remove: defers removal until the queue is flushed" {
    const allocator = std.testing.allocator;

    const TestState = struct {
        var deinits: usize = 0;
    };
    TestState.deinits = 0;

    const Tracked = struct {
        pub fn deinit(_: *@This()) void {
            TestState.deinits += 1;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.resources.addOwned(&world, allocator, Tracked, .{});

    Resources.fromWorld(allocator, &world).remove(allocator, Tracked);
    try std.testing.expectEqual(0, TestState.deinits);
    try std.testing.expect(world.resources.get(Tracked) != null);

    world.resources.flushPending(allocator, &world);

    try std.testing.expectEqual(1, TestState.deinits);
    try std.testing.expectEqual(null, world.resources.get(Tracked));
}

test "queue: defers applying its command until flush" {
    const allocator = std.testing.allocator;

    const TestState = struct {
        var applied_value: u32 = 0;
    };
    TestState.applied_value = 0;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    var state = Resources.State.init();
    defer state.deinit(allocator);

    state.queue(allocator, @as(u32, 7), .{
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

    state.flushPending(allocator, &world);

    try std.testing.expectEqual(7, TestState.applied_value);
}

test "remove: defers invoking the provided function until flush" {
    const allocator = std.testing.allocator;

    const TestState = struct {
        var removed: bool = false;
    };
    TestState.removed = false;

    const removeResource = struct {
        fn call(_: *World, _: std.mem.Allocator) void {
            TestState.removed = true;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    var state = Resources.State.init();
    defer state.deinit(allocator);

    state.pending.pushBack(allocator, .{ .remove = removeResource }) catch unreachable;
    try std.testing.expectEqual(false, TestState.removed);

    state.flushPending(allocator, &world);

    try std.testing.expectEqual(true, TestState.removed);
}

test "addOwned: stores a value that getResource returns" {
    const ClearColor = struct { r: f32, g: f32, b: f32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    world.resources.addOwned(&world, std.testing.allocator, ClearColor, .{ .r = 0, .g = 1, .b = 0 });

    const color = world.resources.get(ClearColor).?;
    try std.testing.expectEqual(ClearColor{ .r = 0, .g = 1, .b = 0 }, color.*);
}

test "addOwned: triggers ResourceAdded" {
    const Event = @import("views/event.zig").Event;

    const buildObserverEntry = @import("../erasure/system_entry.zig").buildObserverEntry;
    const resourceAdded = @import("../events/resource.zig").resourceAdded;

    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const TestState = struct {
        var calls: usize = 0;
    };
    TestState.calls = 0;

    const onAdded = struct {
        fn call(_: Event(ResourceAdded)) void {
            TestState.calls += 1;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, resourceAdded(Config), buildObserverEntry(onAdded, null));
    world.resources.addOwned(&world, allocator, Config, .{ .scale = 1 });

    try std.testing.expectEqual(1, TestState.calls);
}

test "addOwned: triggers Destroying for the old value then Added for the new" {
    const Event = @import("views/event.zig").Event;
    const Resource = @import("views/resource.zig").Resource;

    const buildObserverEntry = @import("../erasure/system_entry.zig").buildObserverEntry;
    const resourceAdded = @import("../events/resource.zig").resourceAdded;
    const resourceDestroying = @import("../events/resource.zig").resourceDestroying;

    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const TestState = struct {
        var log: [4]u8 = undefined;
        var count: usize = 0;
        var scale_at_destroying: ?f32 = null;
        var scale_at_added: ?f32 = null;
    };
    TestState.count = 0;
    TestState.scale_at_destroying = null;
    TestState.scale_at_added = null;

    const Handlers = struct {
        fn onAdded(config: Resource(Config), _: Event(ResourceAdded)) void {
            TestState.log[TestState.count] = 1;
            TestState.count += 1;
            TestState.scale_at_added = config.value.scale;
        }

        fn onDestroying(config: Resource(Config), _: Event(ResourceDestroying)) void {
            TestState.log[TestState.count] = 2;
            TestState.count += 1;
            TestState.scale_at_destroying = config.value.scale;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, resourceAdded(Config), buildObserverEntry(Handlers.onAdded, null));
    world.observers.add(allocator, resourceDestroying(Config), buildObserverEntry(Handlers.onDestroying, null));

    world.resources.addOwned(&world, allocator, Config, .{ .scale = 1 });
    world.resources.addOwned(&world, allocator, Config, .{ .scale = 2 });

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 1 }, TestState.log[0..TestState.count]);
    try std.testing.expectEqual(@as(f32, 1), TestState.scale_at_destroying.?);
    try std.testing.expectEqual(@as(f32, 2), TestState.scale_at_added.?);
}

test "addOwned: does not trigger component events for the same type" {
    const ComponentAdded = @import("../events/component.zig").ComponentAdded;
    const Event = @import("views/event.zig").Event;

    const buildObserverEntry = @import("../erasure/system_entry.zig").buildObserverEntry;
    const componentAdded = @import("../events/component.zig").componentAdded;
    const resourceAdded = @import("../events/resource.zig").resourceAdded;

    const allocator = std.testing.allocator;

    const Shared = struct { value: u32 };

    const TestState = struct {
        var resource_added: usize = 0;
        var component_added: usize = 0;
    };
    TestState.resource_added = 0;
    TestState.component_added = 0;

    const Handlers = struct {
        fn onResource(_: Event(ResourceAdded)) void {
            TestState.resource_added += 1;
        }

        fn onComponent(_: Event(ComponentAdded)) void {
            TestState.component_added += 1;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, resourceAdded(Shared), buildObserverEntry(Handlers.onResource, null));
    world.observers.add(allocator, componentAdded(Shared), buildObserverEntry(Handlers.onComponent, null));

    _ = world.entities.spawnOwned(&world, allocator, .{Shared{ .value = 1 }});
    try std.testing.expectEqual(1, TestState.component_added);
    try std.testing.expectEqual(0, TestState.resource_added);

    world.resources.addOwned(&world, allocator, Shared, .{ .value = 2 });
    try std.testing.expectEqual(1, TestState.component_added);
    try std.testing.expectEqual(1, TestState.resource_added);
}

test "remove: removes the resource and calls its deinit" {
    const TestState = struct {
        var count: usize = 0;
    };
    const Tracked = struct {
        pub fn deinit(_: *@This()) void {
            TestState.count += 1;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    world.resources.addOwned(&world, std.testing.allocator, Tracked, .{});
    world.resources.remove(&world, std.testing.allocator, Tracked);

    try std.testing.expectEqual(1, TestState.count);
    try std.testing.expectEqual(null, world.resources.get(Tracked));
}

test "remove: triggers ResourceDestroying while the value is readable" {
    const Event = @import("views/event.zig").Event;
    const Resource = @import("views/resource.zig").Resource;

    const buildObserverEntry = @import("../erasure/system_entry.zig").buildObserverEntry;
    const resourceDestroying = @import("../events/resource.zig").resourceDestroying;

    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const TestState = struct {
        var seen: ?f32 = null;
    };
    TestState.seen = null;

    const onDestroying = struct {
        fn call(config: Resource(Config), _: Event(ResourceDestroying)) void {
            TestState.seen = config.value.scale;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, resourceDestroying(Config), buildObserverEntry(onDestroying, null));
    world.resources.addOwned(&world, allocator, Config, .{ .scale = 5 });
    world.resources.remove(&world, allocator, Config);

    try std.testing.expectEqual(@as(f32, 5), TestState.seen.?);
    try std.testing.expectEqual(null, world.resources.get(Config));
}

test "remove: triggers nothing for an absent resource" {
    const Event = @import("views/event.zig").Event;

    const buildObserverEntry = @import("../erasure/system_entry.zig").buildObserverEntry;
    const resourceDestroying = @import("../events/resource.zig").resourceDestroying;

    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };

    const TestState = struct {
        var calls: usize = 0;
    };
    TestState.calls = 0;

    const onDestroying = struct {
        fn call(_: Event(ResourceDestroying)) void {
            TestState.calls += 1;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, resourceDestroying(Config), buildObserverEntry(onDestroying, null));
    world.resources.remove(&world, allocator, Config);

    try std.testing.expectEqual(0, TestState.calls);
}
