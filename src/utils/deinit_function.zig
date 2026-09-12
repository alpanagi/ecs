const std = @import("std");

pub const DeinitFunction = *const fn (*anyopaque, std.mem.Allocator) void;
