const hash = @import("../../utils/hash.zig").hash;

pub const ComponentId = enum(u64) {
    _,

    pub fn fromType(T: type) ComponentId {
        return @enumFromInt(hash(T));
    }
};
