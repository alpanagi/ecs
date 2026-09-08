const std = @import("std");

const Resource = @import("../resources/module.zig").Resource;
const SystemsState = @import("state.zig").SystemsState;
const World = @import("../../core/world.zig").World;

pub fn runGroupedSystems(allocator: std.mem.Allocator, world: *World) void {
    const state = Resource(SystemsState).fromWorld(allocator, world).value;
    for (state.groups.items) |group| {
        for (group.systems.items) |thunk| thunk(allocator, world);
    }
}
