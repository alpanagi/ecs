const std = @import("std");

const Archetype = @import("archetype.zig").Archetype;

pub const StorageState = struct {
    archetypes: std.ArrayList(Archetype) = .empty,

    pub fn deinit(self: *StorageState, allocator: std.mem.Allocator) void {
        for (self.archetypes.items) |*archetype| archetype.deinit(allocator);
        self.archetypes.deinit(allocator);
    }
};
