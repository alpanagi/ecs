const std = @import("std");

const Resource = @import("../resources/module.zig").Resource;
const StorageState = @import("state.zig").StorageState;
const World = @import("../../core/world.zig").World;

pub const Entities = struct {
    state: *StorageState,

    pub fn fromWorld(allocator: std.mem.Allocator, world: *World) Entities {
        const resource = Resource(StorageState).fromWorld(allocator, world).value;
        return Entities{ .state = resource };
    }
};
