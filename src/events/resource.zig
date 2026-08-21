const std = @import("std");

const EventId = @import("event_id.zig").EventId;

const hash = @import("../erasure/hash.zig").hash;
const hashBytes = @import("../erasure/hash.zig").hashBytes;
const resourceId = @import("../core/resource.zig").resourceId;

pub const ResourceAdded = struct {
    resource_id: u64,

    pub fn id(self: ResourceAdded) EventId {
        return idFromResourceId(self.resource_id);
    }

    fn idFromResourceId(resource_id: u64) EventId {
        const parts = [_]u64{ hash(ResourceAdded), resource_id };
        return @enumFromInt(hashBytes(std.mem.sliceAsBytes(&parts)));
    }
};

pub const ResourceDestroying = struct {
    resource_id: u64,

    pub fn id(self: ResourceDestroying) EventId {
        return idFromResourceId(self.resource_id);
    }

    fn idFromResourceId(resource_id: u64) EventId {
        const parts = [_]u64{ hash(ResourceDestroying), resource_id };
        return @enumFromInt(hashBytes(std.mem.sliceAsBytes(&parts)));
    }
};

pub fn resourceAdded(comptime T: type) EventId {
    return ResourceAdded.idFromResourceId(resourceId(T));
}

pub fn resourceDestroying(comptime T: type) EventId {
    return ResourceDestroying.idFromResourceId(resourceId(T));
}
