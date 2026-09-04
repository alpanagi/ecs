const std = @import("std");
const mutable_pointer_protocol = @import("../../utils/protocols/mutable_pointer.zig");

const Box = @import("../../utils/box.zig").Box;
const ContextId = @import("context_id.zig").ContextId;
const World = @import("../../core/world.zig").World;

const panic = @import("../../utils/panic.zig").panic;
const panicOom = @import("../../utils/panic.zig").panicOom;

pub const Contexts = struct {
    contexts: *std.AutoHashMapUnmanaged(ContextId, Box),

    pub fn fromWorld(_: std.mem.Allocator, world: *World) Contexts {
        return Contexts{
            .contexts = &world.contexts,
        };
    }

    pub fn addOwned(self: *const Contexts, allocator: std.mem.Allocator, context: anytype) void {
        const PointerType = @TypeOf(context);

        if (comptime !mutable_pointer_protocol.validate(PointerType)) @compileError(
            "Contexts need to be passed as mutable pointers to Contexts.addOwned. Got: " ++
                @typeName(PointerType),
        );

        const ContextType = @typeInfo(PointerType).pointer.child;
        const context_id = ContextId.fromType(ContextType);

        const gop = self.contexts.getOrPut(allocator, context_id) catch panicOom(@This(), @src());
        if (gop.found_existing) panic(
            "Tried to add the same context twice: {s}",
            .{@typeName(ContextType)},
        );

        const context_dupe = allocator.create(ContextType) catch panicOom(@This(), @src());
        context_dupe.* = context.*;
        const context_box = Box.fromOwnedPointer(context_dupe);
        gop.value_ptr.* = context_box;

        context.* = undefined;
    }
};

test "addOwned: adds context to contexts" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const parameter = Contexts.fromWorld(allocator, &world);

    const Context = struct { data: u32 };
    var context: Context = .{ .data = 11 };

    parameter.addOwned(allocator, &context);

    const box = world.contexts.get(ContextId.fromType(Context)).?;
    const saved_context: *Context = @ptrCast(@alignCast(box.value));

    const expected = Context{ .data = 11 };
    try std.testing.expectEqual(expected, saved_context.*);
}
