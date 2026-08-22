const std = @import("std");

pub fn validate(comptime T: type) bool {
    if (!std.meta.hasFn(T, "build")) return false;

    const info = @typeInfo(@TypeOf(T.build)).@"fn";
    if (info.return_type != void) return false;
    if (info.params.len == 0) return false;

    return info.params[0].type == *T;
}
