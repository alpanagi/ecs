const std = @import("std");

const Resources = @import("../resources/module.zig").Resources;
const SystemsState = @import("state.zig").SystemsState;

pub const Systems = @import("parameter.zig").Systems;

pub fn setup(allocator: std.mem.Allocator, resources: Resources) void {
    var state = SystemsState{};

    state.addGroup(allocator, "pre-update", .last);
    state.addGroup(allocator, "update", .last);
    state.addGroup(allocator, "post-update", .last);

    resources.addOwned(allocator, &state);
}
