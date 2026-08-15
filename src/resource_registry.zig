const std = @import("std");

const util = @import("util.zig");
const hash = @import("hash.zig").hash;
const DeinitFunction = @import("deinit.zig").DeinitFunction;
const DestroyFunction = @import("deinit.zig").DestroyFunction;
const getDeinitFunction = @import("deinit.zig").getDeinitFunction;
const getDestroyFunction = @import("deinit.zig").getDestroyFunction;

const ResourceEntry = struct {
    value: *anyopaque,
    deinit: DeinitFunction,
    destroy: DestroyFunction,

    fn release(self: ResourceEntry, allocator: std.mem.Allocator) void {
        self.deinit(allocator, self.value);
        self.destroy(allocator, self.value);
    }
};

pub const ResourceRegistry = struct {
    resources: std.AutoArrayHashMapUnmanaged(u64, ResourceEntry) = .empty,

    pub fn init() ResourceRegistry {
        return .{};
    }

    pub fn deinit(self: *ResourceRegistry, allocator: std.mem.Allocator) void {
        for (self.resources.values()) |entry| entry.release(allocator);
        self.resources.deinit(allocator);
    }

    pub fn addResource(
        self: *ResourceRegistry,
        allocator: std.mem.Allocator,
        comptime T: type,
        value: T,
    ) void {
        const resource = allocator.create(T) catch util.panicOom("ResourceRegistry.addResource");
        resource.* = value;

        const gop = self.resources.getOrPut(allocator, hash(T)) catch
            util.panicOom("ResourceRegistry.addResource");

        if (gop.found_existing) gop.value_ptr.release(allocator);
        gop.value_ptr.* = .{
            .value = resource,
            .deinit = getDeinitFunction(T),
            .destroy = getDestroyFunction(T),
        };
    }

    pub fn getResource(self: *const ResourceRegistry, comptime T: type) ?*T {
        const entry = self.resources.get(hash(T)) orelse return null;
        return @ptrCast(@alignCast(entry.value));
    }

    pub fn removeResource(
        self: *ResourceRegistry,
        allocator: std.mem.Allocator,
        comptime T: type,
    ) void {
        if (self.resources.fetchSwapRemove(hash(T))) |removed| {
            removed.value.release(allocator);
        }
    }
};

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

    var registry = ResourceRegistry.init();
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
    var registry = ResourceRegistry.init();
    registry.addResource(allocator, Owner, .{ .buffer = try allocator.alloc(u8, 16) });

    registry.deinit(allocator);
}

test "addResource: stores a value that getResource returns" {
    const ClearColor = struct { r: f32, g: f32, b: f32 };

    var registry = ResourceRegistry.init();
    defer registry.deinit(std.testing.allocator);

    registry.addResource(std.testing.allocator, ClearColor, .{ .r = 1, .g = 0, .b = 0 });

    const color = registry.getResource(ClearColor).?;
    try std.testing.expectEqual(ClearColor{ .r = 1, .g = 0, .b = 0 }, color.*);
}

test "addResource: replaces an existing resource of the same type" {
    const Counter = struct { value: u32 };

    var registry = ResourceRegistry.init();
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

    var registry = ResourceRegistry.init();
    defer registry.deinit(std.testing.allocator);

    registry.addResource(std.testing.allocator, Tracked, .{});
    registry.addResource(std.testing.allocator, Tracked, .{});

    try std.testing.expectEqual(1, State.count);
}

test "addResource: stores a resource that declares no deinit" {
    const Config = struct { title: []const u8 };

    var registry = ResourceRegistry.init();
    defer registry.deinit(std.testing.allocator);

    registry.addResource(std.testing.allocator, Config, .{ .title = "game" });

    try std.testing.expectEqualStrings("game", registry.getResource(Config).?.title);
}

test "getResource: returns null when the resource was never added" {
    const ClearColor = struct { r: f32, g: f32, b: f32 };

    var registry = ResourceRegistry.init();
    defer registry.deinit(std.testing.allocator);

    try std.testing.expectEqual(null, registry.getResource(ClearColor));
}

test "getResource: returns a pointer that mutates the stored value in place" {
    const Counter = struct { value: u32 };

    var registry = ResourceRegistry.init();
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

    var registry = ResourceRegistry.init();
    defer registry.deinit(std.testing.allocator);

    registry.addResource(std.testing.allocator, Tracked, .{});
    registry.removeResource(std.testing.allocator, Tracked);

    try std.testing.expectEqual(1, State.count);
    try std.testing.expectEqual(null, registry.getResource(Tracked));
}

test "removeResource: does nothing when the resource was never added" {
    const Tracked = struct {};

    var registry = ResourceRegistry.init();
    defer registry.deinit(std.testing.allocator);

    registry.removeResource(std.testing.allocator, Tracked);
}
