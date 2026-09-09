const std = @import("std");

const Resource = @import("../resources/module.zig").Resource;
const OneShotsState = @import("state.zig").OneShotsState;
const World = @import("../../core/world.zig").World;

pub const InternalOneShots = struct {
    state: *OneShotsState,
    world: *World,

    pub fn fromWorld(allocator: std.mem.Allocator, world: *World) InternalOneShots {
        const resource = Resource(OneShotsState).fromWorld(allocator, world).value;
        return InternalOneShots{ .state = resource, .world = world };
    }
};
