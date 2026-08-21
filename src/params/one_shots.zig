const std = @import("std");

const SystemEntry = @import("../erasure/system_entry.zig").SystemEntry;
const World = @import("../core/world.zig").World;

const buildSystemEntry = @import("../erasure/system_entry.zig").buildSystemEntry;
const panicOom = @import("../utils.zig").panicOom;

pub const OneShots = struct {
    pub const State = OneShotsState;

    state: *State,
    world: *World,

    pub fn fromWorld(_: std.mem.Allocator, world: *World) OneShots {
        return .{ .state = &world.one_shots, .world = world };
    }

    pub fn add(
        self: OneShots,
        allocator: std.mem.Allocator,
        comptime function: anytype,
        plugin: anytype,
    ) void {
        self.state.pending.append(allocator, buildSystemEntry(function, plugin)) catch
            panicOom("OneShots.add");
    }
};

const OneShotsState = struct {
    pending: std.ArrayList(SystemEntry) = .empty,

    pub fn init() OneShotsState {
        return .{};
    }

    pub fn deinit(self: *OneShotsState, allocator: std.mem.Allocator) void {
        self.pending.deinit(allocator);
    }
};

test "add: runs a queued system exactly once" {
    const allocator = std.testing.allocator;

    const TestState = struct {
        var calls: usize = 0;
    };
    TestState.calls = 0;

    const system = struct {
        fn call(_: std.mem.Allocator) void {
            TestState.calls += 1;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    OneShots.fromWorld(allocator, &world).add(allocator, system, null);

    world.runSystems(allocator);
    world.runSystems(allocator);

    try std.testing.expectEqual(1, TestState.calls);
    try std.testing.expectEqual(0, world.one_shots.pending.items.len);
}

test "add: runs queued systems in registration order" {
    const allocator = std.testing.allocator;

    const TestState = struct {
        var calls: [2]u8 = undefined;
        var count: usize = 0;
    };
    TestState.count = 0;

    const a = struct {
        fn call() void {
            TestState.calls[TestState.count] = 1;
            TestState.count += 1;
        }
    }.call;
    const b = struct {
        fn call() void {
            TestState.calls[TestState.count] = 2;
            TestState.count += 1;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const one_shots = OneShots.fromWorld(allocator, &world);
    one_shots.add(allocator, a, null);
    one_shots.add(allocator, b, null);

    world.runSystems(allocator);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &TestState.calls);
}

test "add: runs a plugin system through its bound plugin" {
    const allocator = std.testing.allocator;

    const Plugin = struct {
        calls: usize = 0,

        fn tick(self: *@This(), _: std.mem.Allocator) void {
            self.calls += 1;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    var plugin = Plugin{};
    OneShots.fromWorld(allocator, &world).add(allocator, Plugin.tick, &plugin);

    world.runSystems(allocator);

    try std.testing.expectEqual(1, plugin.calls);
}

test "deinit: releases systems queued but never run" {
    const allocator = std.testing.allocator;

    const system = struct {
        fn call() void {}
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const one_shots = OneShots.fromWorld(allocator, &world);
    one_shots.add(allocator, system, null);
    one_shots.add(allocator, system, null);

    try std.testing.expectEqual(2, world.one_shots.pending.items.len);
}
