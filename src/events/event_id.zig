const hash = @import("../erasure/hash.zig").hash;

pub const EventId = enum(u64) { _ };

pub fn eventId(input: anytype) EventId {
    if (@TypeOf(input) == type) return @enumFromInt(hash(input));
    if (@TypeOf(input) == EventId) return input;
    @compileError("expected a type or an EventId, found " ++ @typeName(@TypeOf(input)));
}
