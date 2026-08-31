const hash = @import("../../utils/hash.zig").hash;

pub const ContextId = enum(u64) {
    _,

    pub fn fromType(T: type) ContextId {
        return @enumFromInt(hash(T));
    }
};
