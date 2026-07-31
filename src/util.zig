const std = @import("std");

pub fn panic(comptime message: []const u8, args: anytype) noreturn {
    std.log.err(message, args);
    std.process.exit(1);
}

pub fn EntityComponents(comptime components: []const type) type {
    comptime var pointer_types: [components.len]type = undefined;
    inline for (components, 0..) |component, idx| pointer_types[idx] = *component;
    return @Tuple(&pointer_types);
}
