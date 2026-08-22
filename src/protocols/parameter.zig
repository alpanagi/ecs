const std = @import("std");

const World = @import("../core/world.zig").World;

pub fn validate(comptime T: type) bool {
    if (!std.meta.hasFn(T, "fromWorld")) return false;
    return @TypeOf(T.fromWorld) == fn (std.mem.Allocator, *World) T;
}
