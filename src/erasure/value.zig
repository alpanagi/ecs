const std = @import("std");

const DeinitFunction = @import("deinit.zig").DeinitFunction;
const DestroyFunction = @import("deinit.zig").DestroyFunction;
const World = @import("../core/world.zig").World;

const ApplyFunction = *const fn (*anyopaque, *World, std.mem.Allocator) void;

pub const ValueFunctions = struct {
    apply: ApplyFunction,
    deinit: DeinitFunction,
    destroy: DestroyFunction,
};
