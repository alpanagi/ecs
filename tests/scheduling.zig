const std = @import("std");

const ecs = @import("ecs");

const World = ecs.World;
const Systems = ecs.Systems;

test "integration: a system registered through Systems into an existing group first runs on the next frame" {
    const allocator = std.testing.allocator;

    const system_count = 32;

    const TestState = struct {
        var registered: bool = false;
        var registrar_calls: usize = 0;
        var bystander_calls: usize = 0;
        var added_calls: usize = 0;
    };
    TestState.registered = false;
    TestState.registrar_calls = 0;
    TestState.bystander_calls = 0;
    TestState.added_calls = 0;

    const Fixture = struct {
        fn added() void {
            TestState.added_calls += 1;
        }

        fn registrar(systems: Systems) void {
            TestState.registrar_calls += 1;
            if (TestState.registered) return;
            TestState.registered = true;
            for (0..system_count) |_| systems.add(allocator, "update", added, null);
        }

        fn bystander() void {
            TestState.bystander_calls += 1;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Systems.fromWorld(allocator, &world).add(allocator, "update", Fixture.registrar, null);
    Systems.fromWorld(allocator, &world).add(allocator, "update", Fixture.bystander, null);

    world.runSystems(allocator);
    try std.testing.expectEqual(1, TestState.registrar_calls);
    try std.testing.expectEqual(1, TestState.bystander_calls);
    try std.testing.expectEqual(0, TestState.added_calls);

    world.runSystems(allocator);
    try std.testing.expectEqual(2, TestState.registrar_calls);
    try std.testing.expectEqual(2, TestState.bystander_calls);
    try std.testing.expectEqual(system_count, TestState.added_calls);
}

test "integration: a system registered through Systems into a new group first runs on the next frame" {
    const allocator = std.testing.allocator;

    const group_count = 32;

    const TestState = struct {
        var registered: bool = false;
        var added_calls: usize = 0;
    };
    TestState.registered = false;
    TestState.added_calls = 0;

    const Fixture = struct {
        fn added() void {
            TestState.added_calls += 1;
        }

        fn registrar(systems: Systems) void {
            if (TestState.registered) return;
            TestState.registered = true;
            for (0..group_count) |index| {
                var buffer: [16]u8 = undefined;
                const group = std.fmt.bufPrint(&buffer, "group{d}", .{index}) catch unreachable;
                systems.declareGroup(allocator, group);
                systems.add(allocator, group, added, null);
            }
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.runSystems(allocator);
    const baseline = world.systems.groups.items.len;
    Systems.fromWorld(allocator, &world).add(allocator, "update", Fixture.registrar, null);

    world.runSystems(allocator);
    try std.testing.expectEqual(baseline, world.systems.groups.items.len);
    try std.testing.expectEqual(0, TestState.added_calls);

    world.runSystems(allocator);
    try std.testing.expectEqual(baseline + group_count, world.systems.groups.items.len);
    try std.testing.expectEqual(group_count, TestState.added_calls);
}

test "integration: runs nothing when no system is registered" {
    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    world.runSystems(std.testing.allocator);
}

test "integration: a declared group runs in the position it was placed" {
    const allocator = std.testing.allocator;

    const TestState = struct {
        var calls: [3]u8 = undefined;
        var count: usize = 0;
    };
    TestState.count = 0;

    const Order = struct {
        fn pre(_: std.mem.Allocator) void {
            TestState.calls[TestState.count] = 1;
            TestState.count += 1;
        }
        fn physics(_: std.mem.Allocator) void {
            TestState.calls[TestState.count] = 2;
            TestState.count += 1;
        }
        fn update(_: std.mem.Allocator) void {
            TestState.calls[TestState.count] = 3;
            TestState.count += 1;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Systems.fromWorld(allocator, &world).addGroupAfter(allocator, "pre_update", "physics");

    Systems.fromWorld(allocator, &world).add(allocator, "update", Order.update, null);
    Systems.fromWorld(allocator, &world).add(allocator, "physics", Order.physics, null);
    Systems.fromWorld(allocator, &world).add(allocator, "pre_update", Order.pre, null);

    world.runSystems(allocator);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &TestState.calls);
}
