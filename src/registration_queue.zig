const std = @import("std");

const SystemRegistry = @import("system_registry.zig").SystemRegistry;
const SystemEntry = @import("system_entry.zig").SystemEntry;
const ObserverEntry = @import("system_entry.zig").ObserverEntry;
const EventId = @import("event.zig").EventId;
const World = @import("world.zig").World;
const component = @import("lifecycle.zig").component;
const panicOom = @import("util.zig").panicOom;

const RegistrationCommand = union(enum) {
    add_system: struct {
        group: u64,
        entry: SystemEntry,
    },
    add_one_shot_system: SystemEntry,
    add_observer: struct {
        event_id: EventId,
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
    ) void {
        self.commands.pushBack(allocator, .{ .add_system = .{
            .group = group,
            .entry = entry,
        } }) catch panicOom("RegistrationQueue.addSystem");
    }

    pub fn addOneShotSystem(
        self: *RegistrationQueue,
        allocator: std.mem.Allocator,
        entry: SystemEntry,
    ) void {
        self.commands.pushBack(allocator, .{ .add_one_shot_system = entry }) catch
            panicOom("RegistrationQueue.addOneShotSystem");
    }

    pub fn addObserver(
        self: *RegistrationQueue,
        allocator: std.mem.Allocator,
        event_id: EventId,
        entry: ObserverEntry,
    ) void {
        self.commands.pushBack(allocator, .{ .add_observer = .{
            .event_id = event_id,
            .entry = entry,
        } }) catch panicOom("RegistrationQueue.addObserver");
    }

    pub fn flush(
        self: *RegistrationQueue,
        allocator: std.mem.Allocator,
        registry: *SystemRegistry,
    ) void {
        while (self.commands.popFront()) |command| {
            switch (command) {
                .add_system => |add| registry.addSystemEntry(allocator, add.group, add.entry),
                .add_one_shot_system => |entry| registry.addOneShotSystemEntry(allocator, entry),
                .add_observer => |add| registry.addObserverEntry(allocator, add.event_id, add.entry),
            }
        }
    }
};

test "deinit: discards unflushed commands without applying them" {
    const allocator = std.testing.allocator;

    const entry: SystemEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator) void {}
    }.call };

    var registry = SystemRegistry.init();
    defer registry.deinit(allocator);

    var queue = RegistrationQueue.init();
    queue.addSystem(allocator, 1, entry);
    queue.deinit(allocator);

    try std.testing.expectEqual(0, registry.groups.count());
}

test "addSystem: defers registration until flush" {
    const allocator = std.testing.allocator;

    const entry: SystemEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator) void {}
    }.call };

    var registry = SystemRegistry.init();
    defer registry.deinit(allocator);

    var queue = RegistrationQueue.init();
    defer queue.deinit(allocator);

    queue.addSystem(allocator, 1, entry);
    try std.testing.expectEqual(0, registry.groups.count());

    queue.flush(allocator, &registry);

    try std.testing.expectEqual(1, registry.groups.count());
    try std.testing.expectEqual(1, registry.groups.get(1).?.items.len);
}

test "addOneShotSystem: defers registration until flush" {
    const allocator = std.testing.allocator;

    const entry: SystemEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator) void {}
    }.call };

    var registry = SystemRegistry.init();
    defer registry.deinit(allocator);

    var queue = RegistrationQueue.init();
    defer queue.deinit(allocator);

    queue.addOneShotSystem(allocator, entry);
    try std.testing.expectEqual(0, registry.one_shot_systems.items.len);

    queue.flush(allocator, &registry);

    try std.testing.expectEqual(1, registry.one_shot_systems.items.len);
}

test "addObserver: defers registration until flush" {
    const allocator = std.testing.allocator;

    const Damage = struct { amount: u32 };
    const entry: ObserverEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator, _: *const anyopaque) void {}
    }.call };

    var registry = SystemRegistry.init();
    defer registry.deinit(allocator);

    var queue = RegistrationQueue.init();
    defer queue.deinit(allocator);

    const Position = struct { x: f32, y: f32 };

    queue.addObserver(allocator, EventId.from(Damage), entry);
    queue.addObserver(allocator, component.added(Position), entry);
    try std.testing.expectEqual(0, registry.observers.count());

    queue.flush(allocator, &registry);

    try std.testing.expectEqual(2, registry.observers.count());
    try std.testing.expectEqual(1, registry.observers.get(EventId.from(Damage)).?.items.len);
    try std.testing.expectEqual(1, registry.observers.get(component.added(Position)).?.items.len);
}

test "flush: applies every kind of queued command" {
    const allocator = std.testing.allocator;

    const Damage = struct { amount: u32 };

    const system: SystemEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator) void {}
    }.call };
    const observer: ObserverEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator, _: *const anyopaque) void {}
    }.call };

    var registry = SystemRegistry.init();
    defer registry.deinit(allocator);

    var queue = RegistrationQueue.init();
    defer queue.deinit(allocator);

    queue.addSystem(allocator, 1, system);
    queue.addObserver(allocator, EventId.from(Damage), observer);
    queue.addOneShotSystem(allocator, system);

    queue.flush(allocator, &registry);

    try std.testing.expectEqual(1, registry.groups.get(1).?.items.len);
    try std.testing.expectEqual(1, registry.observers.get(EventId.from(Damage)).?.items.len);
    try std.testing.expectEqual(1, registry.one_shot_systems.items.len);
}

test "flush: leaves the queue empty" {
    const allocator = std.testing.allocator;

    const entry: SystemEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator) void {}
    }.call };

    var registry = SystemRegistry.init();
    defer registry.deinit(allocator);

    var queue = RegistrationQueue.init();
    defer queue.deinit(allocator);

    queue.addSystem(allocator, 1, entry);
    queue.addOneShotSystem(allocator, entry);
    queue.flush(allocator, &registry);

    try std.testing.expectEqual(0, queue.commands.len);
}
