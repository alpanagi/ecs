const std = @import("std");

const DeinitFunction = @import("deinit.zig").DeinitFunction;
const getDeinitFunction = @import("deinit.zig").getDeinitFunction;
const hash = @import("hash.zig").hash;

pub const ComponentDescriptor = struct {
    id: u64,
    size: u32,
    alignment: u32,
    deinit: DeinitFunction,

    pub fn from(comptime T: type) ComponentDescriptor {
        return .{
            .id = hash(T),
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
            .deinit = getDeinitFunction(T),
        };
    }

    pub fn lessThan(_: void, a: ComponentDescriptor, b: ComponentDescriptor) bool {
        return a.id < b.id;
    }

    pub fn orderById(id: u64, component: ComponentDescriptor) std.math.Order {
        return std.math.order(id, component.id);
    }
};

pub const ComponentData = struct {
    id: u64,
    bytes: ?[]const u8,
};
