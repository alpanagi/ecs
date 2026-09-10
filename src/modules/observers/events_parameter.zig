const std = @import("std");

const ObserversState = @import("state.zig").ObserversState;
const Resource = @import("../resources/module.zig").Resource;
const World = @import("../../core/world.zig").World;

pub const Events = struct {
    state: *ObserversState,
    world: *World,

    pub fn fromWorld(allocator: std.mem.Allocator, world: *World) Events {
        const value = Resource(ObserversState).fromWorld(allocator, world).value;
        return Events{ .state = value, .world = world };
    }

    pub fn dispatch(self: Events, allocator: std.mem.Allocator, event: anytype) void {
        self.state.dispatch(allocator, self.world, event);
    }
};
