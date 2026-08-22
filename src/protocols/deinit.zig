const std = @import("std");

pub fn validate(comptime T: type) bool {
    if (!std.meta.hasFn(T, "deinit")) return false;

    const info = @typeInfo(@TypeOf(T.deinit)).@"fn";
    if (info.return_type != void) return false;

    switch (info.params.len) {
        1, 2 => {},
        else => return false,
    }

    const First = info.params[0].type orelse return false;
    if (First != *T and First != *const T) return false;

    if (info.params.len == 2) {
        const Second = info.params[1].type orelse return false;
        if (Second != std.mem.Allocator) return false;
    }

    return true;
}
