const std = @import("std");
const ecs_function_protocol = @import("protocols/ecs_function.zig");
const observers_module = @import("../modules/observers/module.zig");
const one_shots_module = @import("../modules/one_shots/module.zig");
const systems_internal_api = @import("../modules/systems/internal_api.zig");
const systems_module = @import("../modules/systems/module.zig");

const Box = @import("../utils/box.zig").Box;
const ResourceId = @import("../modules/resources/module.zig").ResourceId;

const runSystem = @import("run_system.zig").runSystem;

pub const World = struct {
    resources: std.AutoHashMapUnmanaged(ResourceId, Box) = .empty,

    pub fn init(allocator: std.mem.Allocator) World {
        var world = World{};

        world.addModule(allocator, systems_module.setup);
        world.addModule(allocator, one_shots_module.setup);
        world.addModule(allocator, observers_module.setup);

        return world;
    }

    pub fn deinit(self: *World, allocator: std.mem.Allocator) void {
        var it = self.resources.valueIterator();
        while (it.next()) |box| box.deinit(allocator);
        self.resources.deinit(allocator);
    }

    pub fn addModule(self: *World, allocator: std.mem.Allocator, setup_function: anytype) void {
        const SetupFunctionType = @TypeOf(setup_function);

        if (comptime !ecs_function_protocol.validate(SetupFunctionType, .{}))
            @compileError("Does not implement SetupFunction protocol: " ++
                @typeName(SetupFunctionType));

        runSystem(allocator, self, setup_function);
    }

    pub fn runSystems(self: *World, allocator: std.mem.Allocator) void {
        systems_internal_api.runGroupedSystems(allocator, self);
    }
};

test "deinit: calls the box's deinit" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const Type = struct { data: u32 };
    const resource = try allocator.create(Type);
    resource.* = .{ .data = 11 };

    try world.resources.put(
        allocator,
        ResourceId.fromType(Type),
        Box.fromOwnedPointer(resource),
    );
}

test "runSystems: runs all registered systems in all groups" {
    const Systems = @import("../modules/systems/module.zig").Systems;

    const TestState = struct {
        var system_one_calls: u32 = 0;
        var system_two_calls: u32 = 0;
    };

    const setup_one = struct {
        pub fn setupFunction(allocator: std.mem.Allocator, systems: Systems) void {
            systems.addGroup(allocator, "group_1", .last);
            systems.add(allocator, "group_1", system_one);
        }

        pub fn system_one() void {
            TestState.system_one_calls += 1;
        }
    }.setupFunction;

    const setup_two = struct {
        pub fn setupFunction(allocator: std.mem.Allocator, systems: Systems) void {
            systems.addGroup(allocator, "group_2", .last);
            systems.add(allocator, "group_2", system_two);
        }

        pub fn system_two() void {
            TestState.system_two_calls += 1;
        }
    }.setupFunction;

    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.addModule(allocator, setup_one);
    world.addModule(allocator, setup_two);
    world.runSystems(allocator);

    try std.testing.expectEqual(1, TestState.system_one_calls);
    try std.testing.expectEqual(1, TestState.system_two_calls);
}
