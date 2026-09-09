const std = @import("std");

const GroupPosition = @import("state.zig").GroupPosition;
const Resource = @import("../resources/module.zig").Resource;
const SystemsState = @import("state.zig").SystemsState;
const World = @import("../../core/world.zig").World;

pub const Systems = struct {
    state: *SystemsState,

    pub fn fromWorld(allocator: std.mem.Allocator, world: *World) Systems {
        const resource = Resource(SystemsState).fromWorld(allocator, world).value;
        return Systems{ .state = resource };
    }

    pub fn addGroup(
        self: Systems,
        allocator: std.mem.Allocator,
        group_name: []const u8,
        group_position: GroupPosition,
    ) void {
        self.state.addGroup(allocator, group_name, group_position);
    }

    pub fn add(
        self: Systems,
        allocator: std.mem.Allocator,
        group_name: []const u8,
        system: anytype,
    ) void {
        self.state.add(allocator, group_name, system);
    }
};
