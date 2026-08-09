const std = @import("std");

const World = @import("world.zig").World;

pub fn resolveParameter(comptime Parameter: type, allocator: std.mem.Allocator, world: *World) Parameter {
    if (comptime Parameter == std.mem.Allocator) {
        return allocator;
    } else if (comptime std.meta.hasFn(Parameter, "fromWorld")) {
        return Parameter.fromWorld(allocator, world);
    } else {
        @compileError(
            "unsupported system parameter type " ++ @typeName(Parameter) ++
                ", expected std.mem.Allocator or a type declaring fromWorld",
        );
    }
}

pub fn resolveObserverParameter(
    comptime Parameter: type,
    allocator: std.mem.Allocator,
    world: *World,
    payload: *const anyopaque,
) Parameter {
    if (comptime std.meta.hasFn(Parameter, "fromEvent")) {
        return Parameter.fromEvent(payload);
    }
    return resolveParameter(Parameter, allocator, world);
}