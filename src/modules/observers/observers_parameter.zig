const std = @import("std");

const ObserversState = @import("state.zig").ObserversState;
const Resource = @import("../resources/module.zig").Resource;
const World = @import("../../core/world.zig").World;

pub const Observers = struct {
    state: *ObserversState,

    pub fn fromWorld(allocator: std.mem.Allocator, world: *World) Observers {
        const value = Resource(ObserversState).fromWorld(allocator, world).value;
        return Observers{ .state = value };
    }

    pub fn add(
        self: Observers,
        allocator: std.mem.Allocator,
        EventType: type,
        system: anytype,
    ) void {
        self.state.add(allocator, EventType, system);
    }
};
