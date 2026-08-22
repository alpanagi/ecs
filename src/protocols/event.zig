const std = @import("std");

const EventId = @import("../events/event_id.zig").EventId;

pub fn validate(comptime T: type) bool {
    if (!std.meta.hasFn(T, "id")) return false;
    return @TypeOf(T.id) == fn (T) EventId;
}
