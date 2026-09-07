const hash = @import("../../utils/hash.zig").hash;

pub const ResourceId = enum(u64) {
    _,

    pub fn fromType(T: type) ResourceId {
        return @enumFromInt(hash(T));
    }
};
