const std = @import("std");

const Resource = @import("../resources/module.zig").Resource;
const OneShotsState = @import("state.zig").OneShotsState;
const World = @import("../../core/world.zig").World;

pub const OneShots = struct {
    state: *OneShotsState,

    pub fn fromWorld(allocator: std.mem.Allocator, world: *World) OneShots {
        const resource = Resource(OneShotsState).fromWorld(allocator, world).value;
        return OneShots{ .state = resource };
    }

    pub fn add(self: OneShots, allocator: std.mem.Allocator, system: anytype) void {
        self.state.add(allocator, system);
    }
};
