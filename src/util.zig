const std = @import("std");

pub fn panic(comptime message: []const u8, arguments: anytype) noreturn {
    std.log.err(message, arguments);
    std.process.exit(1);
}

pub fn componentTypes(comptime Components: type) []const type {
    comptime var result: []const type = &.{};
    for (std.meta.fields(Components)) |field| result = result ++ [_]type{field.type};
    return result;
}

pub fn sizedComponents(comptime components: []const type) []const type {
    comptime var result: []const type = &.{};
    for (components) |component| {
        if (@sizeOf(component) > 0) result = result ++ [_]type{component};
    }
    return result;
}

pub fn markerComponents(comptime components: []const type) []const type {
    comptime var result: []const type = &.{};
    for (components) |component| {
        if (@sizeOf(component) == 0) result = result ++ [_]type{component};
    }
    return result;
}

pub fn EntityComponents(comptime components: []const type) type {
    comptime var pointer_types: [components.len]type = undefined;
    inline for (components, 0..) |component, idx| pointer_types[idx] = *component;
    return @Tuple(&pointer_types);
}
