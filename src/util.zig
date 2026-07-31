const std = @import("std");

pub fn panic(comptime message: []const u8, args: anytype) noreturn {
    std.log.err(message, args);
    std.process.exit(1);
}
