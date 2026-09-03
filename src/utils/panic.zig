const std = @import("std");

pub fn panic(comptime text: []const u8, arguments: anytype) noreturn {
    std.log.err(text, arguments);
    std.process.exit(1);
}

pub fn panicOom(T: type, source_location: std.builtin.SourceLocation) noreturn {
    panic("Out of memory in: {s}.{s}", .{ @typeName(T), source_location.fn_name });
}
