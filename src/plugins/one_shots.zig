const std = @import("std");

const OneShots = @import("../params/one_shots.zig").OneShots;
const Systems = @import("../params/systems.zig").Systems;

pub const group = "one_shots";

pub const OneShotsPlugin = struct {
    pub fn build(self: *OneShotsPlugin, allocator: std.mem.Allocator, systems: Systems) void {
        systems.addGroupBefore(allocator, "pre_update", group);
        systems.add(allocator, group, run, self);
    }

    fn run(_: *OneShotsPlugin, one_shots: OneShots, allocator: std.mem.Allocator) void {
        var pending = one_shots.state.pending;
        one_shots.state.pending = .empty;
        defer pending.deinit(allocator);

        for (pending.items) |entry| entry.run(allocator, one_shots.world);
    }
};

test "OneShotsPlugin: registers the runner into the one_shots group" {
    const World = @import("../core/world.zig").World;

    const allocator = std.testing.allocator;

    const groupSystemCount = struct {
        fn call(world: *World, name: []const u8) usize {
            for (world.systems.groups.items) |declared| {
                if (std.mem.eql(u8, declared.name, name)) return declared.systems.items.len;
            }
            return 0;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.systems.flushPending(allocator);

    try std.testing.expectEqual(1, groupSystemCount(&world, group));
}

test "run: a system queueing another does not disturb the running pass" {
    const World = @import("../core/world.zig").World;

    const allocator = std.testing.allocator;

    const TestState = struct {
        var outer: usize = 0;
        var inner: usize = 0;
    };
    TestState.outer = 0;
    TestState.inner = 0;

    const Fixture = struct {
        fn inner() void {
            TestState.inner += 1;
        }

        fn outer(one_shots: OneShots, inner_allocator: std.mem.Allocator) void {
            TestState.outer += 1;
            one_shots.add(inner_allocator, inner, null);
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    OneShots.fromWorld(allocator, &world).add(allocator, Fixture.outer, null);

    world.runSystems(allocator);
    try std.testing.expectEqual(1, TestState.outer);
    try std.testing.expectEqual(0, TestState.inner);

    world.runSystems(allocator);
    try std.testing.expectEqual(1, TestState.outer);
    try std.testing.expectEqual(1, TestState.inner);
}

test "run: a queued system sees entities spawned before the frame" {
    const Query = @import("../params/views/query.zig").Query;
    const World = @import("../core/world.zig").World;

    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    const TestState = struct {
        var seen: usize = 0;
    };
    TestState.seen = 0;

    const startup = struct {
        fn call(positions: Query(&.{Position})) void {
            var it = positions.iterator();
            while (it.next()) |_| TestState.seen += 1;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    _ = world.entities.spawnOwned(&world, allocator, .{Position{ .x = 1, .y = 2 }});
    OneShots.fromWorld(allocator, &world).add(allocator, startup, null);

    world.runSystems(allocator);

    try std.testing.expectEqual(1, TestState.seen);
}

test "run: a system in a later group queues for the next frame" {
    const World = @import("../core/world.zig").World;

    const allocator = std.testing.allocator;

    const TestState = struct {
        var queued: bool = false;
        var calls: usize = 0;
    };
    TestState.queued = false;
    TestState.calls = 0;

    const Fixture = struct {
        fn queued() void {
            TestState.calls += 1;
        }

        fn registrar(one_shots: OneShots, inner: std.mem.Allocator) void {
            if (TestState.queued) return;
            TestState.queued = true;
            one_shots.add(inner, queued, null);
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Systems.fromWorld(allocator, &world).add(allocator, "update", Fixture.registrar, null);

    world.runSystems(allocator);
    try std.testing.expectEqual(0, TestState.calls);

    world.runSystems(allocator);
    try std.testing.expectEqual(1, TestState.calls);
}

test "OneShotsPlugin: declares its group ahead of the baseline schedule" {
    const World = @import("../core/world.zig").World;

    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.systems.flushPending(allocator);

    try std.testing.expectEqualStrings(group, world.systems.groups.items[0].name);
}
