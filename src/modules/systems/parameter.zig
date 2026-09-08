const std = @import("std");

const World = @import("../../core/world.zig").World;

pub const Systems = struct {
    pub fn fromWorld(_: std.mem.Allocator, _: *World) Systems {
        return Systems{};
    }
};
