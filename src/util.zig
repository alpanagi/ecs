const std = @import("std");

pub fn panic(comptime message: []const u8, arguments: anytype) noreturn {
    std.log.err(message, arguments);
    std.process.exit(1);
}

pub fn panicOom(comptime function_name: []const u8) noreturn {
    panic(function_name ++ ": out of memory", .{});
}
