const std = @import("std");

const Resources = @import("../resources/module.zig").Resources;
const StorageState = @import("state.zig").StorageState;

pub fn setup(allocator: std.mem.Allocator, resources: Resources) void {
    var state = StorageState{};
    resources.addOwned(allocator, &state);
}
