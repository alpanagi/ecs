const std = @import("std");
const system_protocol = @import("../../core/protocols/system.zig");

const World = @import("../../core/world.zig").World;

const panic = @import("../../utils/panic.zig").panic;
const panicOom = @import("../../utils/panic.zig").panicOom;
const runSystem = @import("../../core/run_system.zig").runSystem;

pub const SystemsState = struct {
    groups: std.StringArrayHashMapUnmanaged(std.ArrayList(Thunk)) = .empty,

    pub fn deinit(self: *SystemsState, allocator: std.mem.Allocator) void {
        for (self.groups.values()) |*group| group.deinit(allocator);
        self.groups.deinit(allocator);
    }

    pub fn add(
        self: *SystemsState,
        allocator: std.mem.Allocator,
        group: []const u8,
        system: anytype,
    ) void {
        const SystemType = @TypeOf(system);

        if (comptime !system_protocol.validate(SystemType))
            @compileError("Does not implement System protocol: " ++ @typeName(SystemType));

        const group_systems = self.groups.getPtr(group) orelse
            panic("Tried to add system to unknown group: {s}", .{group});

        const thunk = struct {
            pub fn function(inner_allocator: std.mem.Allocator, world: *World) void {
                runSystem(inner_allocator, world, system);
            }
        }.function;

        group_systems.append(allocator, &thunk) catch panicOom(@This(), @src());
    }
};

const Thunk = *const fn (std.mem.Allocator, *World) void;

test "deinit: deallocates groups" {
    const allocator = std.testing.allocator;

    const thunk = struct {
        pub fn function(_: std.mem.Allocator, _: *World) void {}
    }.function;

    var state = SystemsState{};
    defer state.deinit(allocator);

    try state.groups.put(allocator, "group", .empty);
    try state.groups.getPtr("group").?.append(allocator, &thunk);
}

test "add: appends system to the correct group" {
    const allocator = std.testing.allocator;

    const system = struct {
        pub fn function(_: std.mem.Allocator) void {}
    }.function;

    var state = SystemsState{};
    defer state.deinit(allocator);

    try state.groups.put(allocator, "group_1", .empty);
    try state.groups.put(allocator, "group_2", .empty);

    state.add(allocator, "group_2", system);

    try std.testing.expectEqual(0, state.groups.get("group_1").?.items.len);
    try std.testing.expectEqual(1, state.groups.get("group_2").?.items.len);
}

test "add: creates a thunk that calls the passed system" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const TestState = struct {
        var system_calls: u32 = 0;
    };

    const system = struct {
        pub fn function(_: std.mem.Allocator) void {
            TestState.system_calls += 1;
        }
    }.function;

    var state = SystemsState{};
    defer state.deinit(allocator);

    try state.groups.put(allocator, "group", .empty);

    state.add(allocator, "group", system);

    state.groups.getPtr("group").?.items[0](allocator, &world);

    try std.testing.expectEqual(1, TestState.system_calls);
}
