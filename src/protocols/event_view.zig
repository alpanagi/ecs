const std = @import("std");

pub fn validate(comptime T: type) bool {
    if (!std.meta.hasFn(T, "fromEvent")) return false;
    return @TypeOf(T.fromEvent) == fn (*const anyopaque) T;
}
