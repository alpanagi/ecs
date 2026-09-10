const std = @import("std");

const OneShotsState = @import("state.zig").OneShotsState;
const Resources = @import("../resources/module.zig").Resources;
const Systems = @import("../systems/module.zig").Systems;

pub const OneShots = @import("parameter.zig").OneShots;

pub fn setup(allocator: std.mem.Allocator, resources: Resources, systems: Systems) void {
    var state = OneShotsState{};
    resources.addOwned(allocator, &state);

    systems.addGroup(allocator, "one-shots", .{ .before = "pre-update" });
    systems.add(allocator, "one-shots", runOneShots);
}

fn runOneShots(allocator: std.mem.Allocator, one_shots: OneShots) void {
    var pending_systems = one_shots.state.pending_systems;
    one_shots.state.pending_systems = .empty;

    for (pending_systems.items) |thunk| {
        thunk(allocator, one_shots.world);
    }

    pending_systems.deinit(allocator);
}

test "runOneShots: runs and then removes pending one shots" {
    const Resource = @import("../resources/module.zig").Resource;
    const World = @import("../../core/world.zig").World;

    const TestState = struct {
        var system_calls: u32 = 0;
    };

    const setup_function = struct {
        pub fn function(allocator: std.mem.Allocator, one_shots: OneShots) void {
            one_shots.add(allocator, system);
        }

        pub fn system() void {
            TestState.system_calls += 1;
        }
    }.function;

    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.addModule(allocator, setup_function);

    const one_shots_state = Resource(OneShotsState).fromWorld(allocator, &world).value;

    try std.testing.expectEqual(1, one_shots_state.pending_systems.items.len);
    world.runSystems(allocator);
    try std.testing.expectEqual(0, one_shots_state.pending_systems.items.len);
    try std.testing.expectEqual(1, TestState.system_calls);
}

test "runOneShots: one shots added during one shots execution are deferred to the next runSystems" {
    const Resource = @import("../resources/module.zig").Resource;
    const World = @import("../../core/world.zig").World;

    const TestState = struct {
        var system_calls: u32 = 0;
    };

    const setup_function = struct {
        pub fn function(allocator: std.mem.Allocator, one_shots: OneShots) void {
            one_shots.add(allocator, system_one);
        }

        pub fn system_one(allocator: std.mem.Allocator, one_shots: OneShots) void {
            TestState.system_calls += 1;
            one_shots.add(allocator, system_two);
        }

        pub fn system_two() void {
            TestState.system_calls += 1;
        }
    }.function;

    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.addModule(allocator, setup_function);

    const one_shots_state = Resource(OneShotsState).fromWorld(allocator, &world).value;

    try std.testing.expectEqual(1, one_shots_state.pending_systems.items.len);
    world.runSystems(allocator);
    try std.testing.expectEqual(1, one_shots_state.pending_systems.items.len);
    try std.testing.expectEqual(1, TestState.system_calls);

    world.runSystems(allocator);
    try std.testing.expectEqual(0, one_shots_state.pending_systems.items.len);
    try std.testing.expectEqual(2, TestState.system_calls);
}
