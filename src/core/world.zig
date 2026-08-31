const std = @import("std");

const Box = @import("../utils/box.zig").Box;
const ContextId = @import("../modules/contexts/module.zig").ContextId;

pub const World = struct {
    contexts: std.AutoHashMapUnmanaged(ContextId, Box) = .empty,

    pub fn init() World {
        return World{};
    }

    pub fn deinit(self: *World, allocator: std.mem.Allocator) void {
        var it = self.contexts.valueIterator();
        while (it.next()) |box| box.deinit(allocator);
        self.contexts.deinit(allocator);
    }
};

test "deinit: calls the box's deinit" {
    const allocator = std.testing.allocator;

    var world = World.init();
    defer world.deinit(allocator);

    const Context = struct { data: u32 };
    const context = try allocator.create(Context);
    context.* = .{ .data = 11 };

    try world.contexts.put(allocator, ContextId.fromType(Context), Box.fromOwnedPointer(context));
}
