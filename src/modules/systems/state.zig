const std = @import("std");
const system_protocol = @import("../../core/protocols/system.zig");

const World = @import("../../core/world.zig").World;

const panic = @import("../../utils/panic.zig").panic;
const panicOom = @import("../../utils/panic.zig").panicOom;
const runSystem = @import("../../core/run_system.zig").runSystem;

pub const SystemsState = struct {
    groups: std.ArrayList(Group) = .empty,

    pub fn deinit(self: *SystemsState, allocator: std.mem.Allocator) void {
        for (self.groups.items) |*group| {
            allocator.free(group.name);
            group.systems.deinit(allocator);
        }
        self.groups.deinit(allocator);
    }

    pub fn addGroup(
        self: *SystemsState,
        allocator: std.mem.Allocator,
        group_name: []const u8,
    ) void {
        for (self.groups.items) |*group| {
            if (std.mem.eql(u8, group_name, group.name)) panic(
                "Tried to add a group twice: {s}",
                .{group_name},
            );
        }

        self.groups.append(allocator, .{
            .name = allocator.dupe(u8, group_name) catch panicOom(@This(), @src()),
            .systems = .empty,
        }) catch panicOom(@This(), @src());
    }

    pub fn add(
        self: *SystemsState,
        allocator: std.mem.Allocator,
        group_name: []const u8,
        system: anytype,
    ) void {
        const SystemType = @TypeOf(system);

        if (comptime !system_protocol.validate(SystemType))
            @compileError("Does not implement System protocol: " ++ @typeName(SystemType));

        const group = for (self.groups.items) |*group| {
            if (std.mem.eql(u8, group_name, group.name)) break group;
        } else panic("Tried to add system to unknown group: {s}", .{group_name});

        const thunk = struct {
            pub fn function(inner_allocator: std.mem.Allocator, world: *World) void {
                runSystem(inner_allocator, world, system);
            }
        }.function;

        group.systems.append(allocator, &thunk) catch panicOom(@This(), @src());
    }
};

const Group = struct {
    name: []const u8,
    systems: std.ArrayList(Thunk),
};

const Thunk = *const fn (std.mem.Allocator, *World) void;

test "deinit: deallocates groups" {
    const allocator = std.testing.allocator;

    const thunk = struct {
        pub fn function(_: std.mem.Allocator, _: *World) void {}
    }.function;

    var state = SystemsState{};
    defer state.deinit(allocator);

    state.addGroup(allocator, "group");
    try state.groups.items[0].systems.append(allocator, &thunk);
}

test "addGroup: adds group to the group list" {
    const allocator = std.testing.allocator;

    var state = SystemsState{};
    defer state.deinit(allocator);

    state.addGroup(allocator, "group");
    try std.testing.expectEqualSlices(u8, "group", state.groups.items[0].name);
}

test "add: appends system to the correct group" {
    const allocator = std.testing.allocator;

    const system = struct {
        pub fn function(_: std.mem.Allocator) void {}
    }.function;

    var state = SystemsState{};
    defer state.deinit(allocator);

    state.addGroup(allocator, "group_1");
    state.addGroup(allocator, "group_2");
    state.add(allocator, "group_2", system);

    try std.testing.expectEqual(0, state.groups.items[0].systems.items.len);
    try std.testing.expectEqual(1, state.groups.items[1].systems.items.len);
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

    state.addGroup(allocator, "group");
    state.add(allocator, "group", system);

    state.groups.items[0].systems.items[0](allocator, &world);

    try std.testing.expectEqual(1, TestState.system_calls);
}
