const hash = @import("../../utils/hash.zig").hash;

pub const EventId = enum(u64) {
    _,

    pub fn fromType(T: type) EventId {
        return @enumFromInt(hash(T));
    }
};
