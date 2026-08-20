const std = @import("std");

const World = @import("../core/world.zig").World;
const Systems = @import("systems.zig").Systems;
const SystemEntry = @import("../erasure/system_entry.zig").SystemEntry;
const buildSystemEntry = @import("../erasure/system_entry.zig").buildSystemEntry;
const panicOom = @import("../utils.zig").panicOom;

pub const group = "one_shots";

pub const OneShots = struct {
    pub const State = OneShotsState;

    state: *State,
    world: *World,

    pub fn fromWorld(_: std.mem.Allocator, world: *World) OneShots {
        return .{ .state = &world.one_shots, .world = world };
    }

    pub fn addSystem(
        self: OneShots,
        allocator: std.mem.Allocator,
        comptime function: anytype,
        plugin: anytype,
    ) void {
        self.state.pending.append(allocator, buildSystemEntry(function, plugin)) catch
            panicOom("OneShots.addSystem");
    }

    pub fn run(self: OneShots, allocator: std.mem.Allocator) void {
        var pending = self.state.pending;
        self.state.pending = .empty;
        defer pending.deinit(allocator);

        for (pending.items) |entry| entry.run(allocator, self.world);
    }
};

const OneShotsState = struct {
    pending: std.ArrayList(SystemEntry) = .empty,

    pub fn deinit(self: *OneShotsState, allocator: std.mem.Allocator) void {
        self.pending.deinit(allocator);
    }
};

test "init: registers the runner into the one_shots group" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    try std.testing.expectEqual(1, world.systems.findGroup(group).?.systems.items.len);
}

test "addSystem: runs a queued system exactly once" {
    const allocator = std.testing.allocator;

    const State = struct {
        var calls: usize = 0;
    };
    State.calls = 0;

    const system = struct {
        fn call(_: std.mem.Allocator) void {
            State.calls += 1;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    OneShots.fromWorld(allocator, &world).addSystem(allocator, system, null);

    world.runSystems(allocator);
    world.runSystems(allocator);

    try std.testing.expectEqual(1, State.calls);
    try std.testing.expectEqual(0, world.one_shots.pending.items.len);
}

test "addSystem: runs queued systems in registration order" {
    const allocator = std.testing.allocator;

    const State = struct {
        var calls: [2]u8 = undefined;
        var count: usize = 0;
    };
    State.count = 0;

    const a = struct {
        fn call() void {
            State.calls[State.count] = 1;
            State.count += 1;
        }
    }.call;
    const b = struct {
        fn call() void {
            State.calls[State.count] = 2;
            State.count += 1;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const one_shots = OneShots.fromWorld(allocator, &world);
    one_shots.addSystem(allocator, a, null);
    one_shots.addSystem(allocator, b, null);

    world.runSystems(allocator);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &State.calls);
}

test "addSystem: runs a plugin system through its bound plugin" {
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
    OneShots.fromWorld(allocator, &world).addSystem(allocator, Plugin.tick, &plugin);

    world.runSystems(allocator);

    try std.testing.expectEqual(1, plugin.calls);
}

test "run: a system queueing another does not disturb the running pass" {
    const allocator = std.testing.allocator;

    const State = struct {
        var outer: usize = 0;
        var inner: usize = 0;
    };
    State.outer = 0;
    State.inner = 0;

    const Fixture = struct {
        fn inner() void {
            State.inner += 1;
        }

        fn outer(one_shots: OneShots, inner_allocator: std.mem.Allocator) void {
            State.outer += 1;
            one_shots.addSystem(inner_allocator, inner, null);
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    OneShots.fromWorld(allocator, &world).addSystem(allocator, Fixture.outer, null);

    world.runSystems(allocator);
    try std.testing.expectEqual(1, State.outer);
    try std.testing.expectEqual(0, State.inner);

    world.runSystems(allocator);
    try std.testing.expectEqual(1, State.outer);
    try std.testing.expectEqual(1, State.inner);
}

test "run: a queued system sees entities spawned before the frame" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const State = struct {
        var seen: usize = 0;
    };
    State.seen = 0;

    const startup = struct {
        fn call(positions: @import("views/query.zig").Query(&.{Position})) void {
            var it = positions.iterator();
            while (it.next()) |_| State.seen += 1;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.addOwnedEntity(allocator, .{Position{ .x = 1, .y = 2 }});
    OneShots.fromWorld(allocator, &world).addSystem(allocator, startup, null);

    world.runSystems(allocator);

    try std.testing.expectEqual(1, State.seen);
}

test "deinit: releases systems queued but never run" {
    const allocator = std.testing.allocator;

    const system = struct {
        fn call() void {}
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const one_shots = OneShots.fromWorld(allocator, &world);
    one_shots.addSystem(allocator, system, null);
    one_shots.addSystem(allocator, system, null);

    try std.testing.expectEqual(2, world.one_shots.pending.items.len);
}

test "run: a system in a later group queues for the next frame" {
    const allocator = std.testing.allocator;

    const State = struct {
        var queued: bool = false;
        var calls: usize = 0;
    };
    State.queued = false;
    State.calls = 0;

    const Fixture = struct {
        fn queued() void {
            State.calls += 1;
        }

        fn registrar(one_shots: OneShots, inner: std.mem.Allocator) void {
            if (State.queued) return;
            State.queued = true;
            one_shots.addSystem(inner, queued, null);
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Systems.fromWorld(allocator, &world).addSystem(allocator, "update", Fixture.registrar, null);

    world.runSystems(allocator);
    try std.testing.expectEqual(0, State.calls);

    world.runSystems(allocator);
    try std.testing.expectEqual(1, State.calls);
}
