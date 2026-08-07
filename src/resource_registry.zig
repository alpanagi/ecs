const std = @import("std");

const hash = @import("hash.zig").hash;
const DeinitFunction = @import("deinit.zig").DeinitFunction;
const getDeinitFunction = @import("deinit.zig").getDeinitFunction;

const ResourceEntry = struct {
    value: *anyopaque,
    deinit: DeinitFunction,
};

pub const ResourceRegistry = struct {
    resources: std.AutoArrayHashMapUnmanaged(u64, ResourceEntry) = .{},

    pub fn init() ResourceRegistry {
        return .{};
    }

    pub fn deinit(self: *ResourceRegistry, allocator: std.mem.Allocator) void {
        for (self.resources.values()) |entry| entry.deinit(entry.value, allocator);
        self.resources.deinit(allocator);
    }

    pub fn addResource(
        self: *ResourceRegistry,
        allocator: std.mem.Allocator,
        comptime T: type,
        value: T,
    ) !void {
        const resource = try allocator.create(T);
        errdefer allocator.destroy(resource);
        resource.* = value;

        const gop = try self.resources.getOrPut(allocator, hash(T));
        if (gop.found_existing) gop.value_ptr.deinit(gop.value_ptr.value, allocator);
        gop.value_ptr.* = .{ .value = resource, .deinit = getDeinitFunction(T) };
    }

    pub fn getResource(self: *ResourceRegistry, comptime T: type) ?*T {
        const entry = self.resources.get(hash(T)) orelse return null;
        return @ptrCast(@alignCast(entry.value));
    }

    pub fn removeResource(
        self: *ResourceRegistry,
        allocator: std.mem.Allocator,
        comptime T: type,
    ) void {
        if (self.resources.fetchOrderedRemove(hash(T))) |removed| {
            removed.value.deinit(removed.value.value, allocator);
        }
    }
};

test "addResource then getResource returns the stored value" {
    const ClearColor = struct { r: f32, g: f32, b: f32 };

    var registry = ResourceRegistry.init();
    defer registry.deinit(std.testing.allocator);

    try registry.addResource(std.testing.allocator, ClearColor, .{ .r = 1, .g = 0, .b = 0 });

    const color = registry.getResource(ClearColor).?;
    try std.testing.expectEqual(ClearColor{ .r = 1, .g = 0, .b = 0 }, color.*);
}

test "getResource returns null when the resource was never added" {
    const ClearColor = struct { r: f32, g: f32, b: f32 };

    var registry = ResourceRegistry.init();
    defer registry.deinit(std.testing.allocator);

    try std.testing.expectEqual(null, registry.getResource(ClearColor));
}

test "getResource returns a pointer that can mutate the stored value in place" {
    const Counter = struct { value: u32 };

    var registry = ResourceRegistry.init();
    defer registry.deinit(std.testing.allocator);

    try registry.addResource(std.testing.allocator, Counter, .{ .value = 0 });

    registry.getResource(Counter).?.value += 1;
    registry.getResource(Counter).?.value += 1;

    try std.testing.expectEqual(2, registry.getResource(Counter).?.value);
}

test "addResource replaces an existing resource of the same type" {
    const Counter = struct { value: u32 };

    var registry = ResourceRegistry.init();
    defer registry.deinit(std.testing.allocator);

    try registry.addResource(std.testing.allocator, Counter, .{ .value = 1 });
    try registry.addResource(std.testing.allocator, Counter, .{ .value = 2 });

    try std.testing.expectEqual(1, registry.resources.count());
    try std.testing.expectEqual(2, registry.getResource(Counter).?.value);
}

test "addResource calls the old value's deinit when replacing it" {
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

    try registry.addResource(std.testing.allocator, Tracked, .{});
    try registry.addResource(std.testing.allocator, Tracked, .{});

    try std.testing.expectEqual(1, State.count);
}

test "removeResource removes it and calls its deinit" {
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

    try registry.addResource(std.testing.allocator, Tracked, .{});
    registry.removeResource(std.testing.allocator, Tracked);

    try std.testing.expectEqual(1, State.count);
    try std.testing.expectEqual(null, registry.getResource(Tracked));
}

test "removeResource is a no-op when the resource was never added" {
    const Tracked = struct {};

    var registry = ResourceRegistry.init();
    defer registry.deinit(std.testing.allocator);

    registry.removeResource(std.testing.allocator, Tracked);
}

test "deinit calls deinit on every remaining resource" {
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
    try registry.addResource(std.testing.allocator, A, .{});
    try registry.addResource(std.testing.allocator, B, .{});

    registry.deinit(std.testing.allocator);

    try std.testing.expectEqual(2, State.count);
}

test "a resource without deinit is freed without error" {
    const Config = struct { title: []const u8 };

    var registry = ResourceRegistry.init();
    defer registry.deinit(std.testing.allocator);

    try registry.addResource(std.testing.allocator, Config, .{ .title = "game" });
}
