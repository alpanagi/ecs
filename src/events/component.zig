const std = @import("std");

const Entity = @import("../core/entity.zig").Entity;
const EventId = @import("event_id.zig").EventId;

const componentId = @import("../core/component.zig").componentId;
const hash = @import("../erasure/hash.zig").hash;
const hashBytes = @import("../erasure/hash.zig").hashBytes;

pub const ComponentAdded = struct {
    entity: Entity,
    component_id: u64,

    pub fn id(self: ComponentAdded) EventId {
        return idFromComponentId(self.component_id);
    }

    fn idFromComponentId(component_id: u64) EventId {
        const parts = [_]u64{ hash(ComponentAdded), component_id };
        return @enumFromInt(hashBytes(std.mem.sliceAsBytes(&parts)));
    }
};

pub const ComponentDestroying = struct {
    entity: Entity,
    component_id: u64,

    pub fn id(self: ComponentDestroying) EventId {
        return idFromComponentId(self.component_id);
    }

    fn idFromComponentId(component_id: u64) EventId {
        const parts = [_]u64{ hash(ComponentDestroying), component_id };
        return @enumFromInt(hashBytes(std.mem.sliceAsBytes(&parts)));
    }
};

pub fn componentAdded(comptime T: type) EventId {
    return ComponentAdded.idFromComponentId(componentId(T));
}

pub fn componentDestroying(comptime T: type) EventId {
    return ComponentDestroying.idFromComponentId(componentId(T));
}
