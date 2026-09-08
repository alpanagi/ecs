const std = @import("std");

const World = @import("../../core/world.zig").World;

pub const SystemsState = struct {
    groups: std.ArrayList(std.ArrayList(System)) = .empty,

    pub fn deinit(self: *SystemsState, allocator: std.mem.Allocator) void {
        for (self.groups.items) |*group| group.deinit(allocator);
        self.groups.deinit(allocator);
    }
};

pub const System = struct {
    thunk: *const fn (std.mem.Allocator, *World) void,
};

test "deinit: deallocates groups" {
    const allocator = std.testing.allocator;

    const system = struct {
        pub fn function(_: std.mem.Allocator, _: *World) void {}
    }.function;

    var state = SystemsState{};
    try state.groups.append(allocator, .empty);
    try state.groups.items[0].append(allocator, System{ .thunk = &system });

    state.deinit(allocator);
}
