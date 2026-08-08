const std = @import("std");

const SystemRegistry = @import("system_registry.zig").SystemRegistry;
const SystemEntry = @import("system_registry.zig").SystemEntry;
const ObserverEntry = @import("system_registry.zig").ObserverEntry;

const RegistrationCommand = union(enum) {
    add_system: struct {
        group: u64,
        entry: SystemEntry,
    },
    add_one_shot_system: struct {
        entry: SystemEntry,
    },
    add_observer: struct {
        event: u64,
        entry: ObserverEntry,
    },
};

pub const RegistrationQueue = struct {
    commands: std.Deque(RegistrationCommand) = .empty,

    pub fn init() RegistrationQueue {
        return .{};
    }

    pub fn deinit(self: *RegistrationQueue, allocator: std.mem.Allocator) void {
        self.commands.deinit(allocator);
    }

    pub fn addSystem(
        self: *RegistrationQueue,
        allocator: std.mem.Allocator,
        group: u64,
        entry: SystemEntry,
    ) !void {
        try self.commands.pushBack(allocator, .{ .add_system = .{
            .group = group,
            .entry = entry,
        } });
    }

    pub fn addOneShotSystem(
        self: *RegistrationQueue,
        allocator: std.mem.Allocator,
        entry: SystemEntry,
    ) !void {
        try self.commands.pushBack(allocator, .{ .add_one_shot_system = .{ .entry = entry } });
    }

    pub fn addObserver(
        self: *RegistrationQueue,
        allocator: std.mem.Allocator,
        event: u64,
        entry: ObserverEntry,
    ) !void {
        try self.commands.pushBack(allocator, .{ .add_observer = .{
            .event = event,
            .entry = entry,
        } });
    }

    pub fn flush(
        self: *RegistrationQueue,
        allocator: std.mem.Allocator,
        registry: *SystemRegistry,
    ) !void {
        while (self.commands.popFront()) |command| {
            switch (command) {
                .add_system => |add| try registry.addSystemEntry(allocator, add.group, add.entry),
                .add_one_shot_system => |add| try registry.addOneShotSystemEntry(allocator, add.entry),
                .add_observer => |add| try registry.addObserverEntry(allocator, add.event, add.entry),
            }
        }
    }
};

test "RegistrationQueue.addSystem defers registration until flush" {
    const allocator = std.testing.allocator;
    const World = @import("world.zig").World;

    const entry: SystemEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator) anyerror!void {}
    }.call };

    var registry = SystemRegistry.init();
    defer registry.deinit(allocator);

    var queue = RegistrationQueue.init();
    defer queue.deinit(allocator);

    try queue.addSystem(allocator, 1, entry);
    try std.testing.expectEqual(0, registry.groups.count());

    try queue.flush(allocator, &registry);

    try std.testing.expectEqual(1, registry.groups.count());
    try std.testing.expectEqual(1, registry.groups.get(1).?.items.len);
}

test "RegistrationQueue.addOneShotSystem defers registration until flush" {
    const allocator = std.testing.allocator;
    const World = @import("world.zig").World;

    const entry: SystemEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator) anyerror!void {}
    }.call };

    var registry = SystemRegistry.init();
    defer registry.deinit(allocator);

    var queue = RegistrationQueue.init();
    defer queue.deinit(allocator);

    try queue.addOneShotSystem(allocator, entry);
    try std.testing.expectEqual(0, registry.one_shot_systems.items.len);

    try queue.flush(allocator, &registry);

    try std.testing.expectEqual(1, registry.one_shot_systems.items.len);
}

test "RegistrationQueue.addObserver defers registration until flush" {
    const allocator = std.testing.allocator;
    const World = @import("world.zig").World;
    const hash = @import("hash.zig").hash;

    const Damage = struct { amount: u32 };
    const entry: ObserverEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator, _: *const anyopaque) anyerror!void {}
    }.call };

    var registry = SystemRegistry.init();
    defer registry.deinit(allocator);

    var queue = RegistrationQueue.init();
    defer queue.deinit(allocator);

    try queue.addObserver(allocator, hash(Damage), entry);
    try std.testing.expectEqual(0, registry.observers.count());

    try queue.flush(allocator, &registry);

    try std.testing.expectEqual(1, registry.observers.get(hash(Damage)).?.items.len);
}

test "RegistrationQueue.flush applies commands in the order they were enqueued" {
    const allocator = std.testing.allocator;
    const World = @import("world.zig").World;

    const entry: SystemEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator) anyerror!void {}
    }.call };

    var registry = SystemRegistry.init();
    defer registry.deinit(allocator);

    var queue = RegistrationQueue.init();
    defer queue.deinit(allocator);

    try queue.addSystem(allocator, 2, entry);
    try queue.addSystem(allocator, 1, entry);
    try queue.addSystem(allocator, 2, entry);

    try queue.flush(allocator, &registry);

    try std.testing.expectEqualSlices(u64, &.{ 2, 1 }, registry.groups.keys());
    try std.testing.expectEqual(2, registry.groups.get(2).?.items.len);
}

test "RegistrationQueue.flush leaves the queue empty" {
    const allocator = std.testing.allocator;
    const World = @import("world.zig").World;

    const entry: SystemEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator) anyerror!void {}
    }.call };

    var registry = SystemRegistry.init();
    defer registry.deinit(allocator);

    var queue = RegistrationQueue.init();
    defer queue.deinit(allocator);

    try queue.addSystem(allocator, 1, entry);
    try queue.addOneShotSystem(allocator, entry);
    try queue.flush(allocator, &registry);

    try std.testing.expectEqual(0, queue.commands.len);
}

test "RegistrationQueue.deinit discards unflushed commands without applying them" {
    const allocator = std.testing.allocator;
    const World = @import("world.zig").World;

    const entry: SystemEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator) anyerror!void {}
    }.call };

    var registry = SystemRegistry.init();
    defer registry.deinit(allocator);

    var queue = RegistrationQueue.init();
    try queue.addSystem(allocator, 1, entry);
    queue.deinit(allocator);

    try std.testing.expectEqual(0, registry.groups.count());
}
