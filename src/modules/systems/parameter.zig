const std = @import("std");

const Resource = @import("../resources/module.zig").Resource;
const SystemsState = @import("state.zig").SystemsState;
const World = @import("../../core/world.zig").World;

pub const Systems = struct {
    state: *SystemsState,

    pub fn fromWorld(allocator: std.mem.Allocator, world: *World) Systems {
        const resource = Resource(SystemsState).fromWorld(allocator, world).value;
        return Systems{ .state = resource };
    }
};
