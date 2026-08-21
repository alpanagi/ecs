pub const DeinitFunction = @import("erasure/deinit.zig").DeinitFunction;
pub const Entities = @import("params/entities.zig").Entities;
pub const Entity = @import("core/entity.zig").Entity;
pub const Event = @import("params/views/event.zig").Event;
pub const EventId = @import("core/event_id.zig").EventId;
pub const Observers = @import("params/observers.zig").Observers;
pub const OneShots = @import("params/one_shots.zig").OneShots;
pub const Query = @import("params/views/query.zig").Query;
pub const Resource = @import("params/views/resource.zig").Resource;
pub const Resources = @import("params/resources.zig").Resources;
pub const Systems = @import("params/systems.zig").Systems;
pub const World = @import("core/world.zig").World;

pub const componentId = @import("core/component.zig").componentId;
pub const getDeinitFunction = @import("erasure/deinit.zig").getDeinitFunction;

pub const events = struct {
    pub const component = @import("core/lifecycle.zig").component;
    pub const resource = @import("core/lifecycle.zig").resource;

    pub const ComponentAdded = @import("core/lifecycle.zig").ComponentAdded;
    pub const ComponentDestroying = @import("core/lifecycle.zig").ComponentDestroying;
    pub const ResourceAdded = @import("core/lifecycle.zig").ResourceAdded;
    pub const ResourceDestroying = @import("core/lifecycle.zig").ResourceDestroying;
};

test {
    _ = @import("core/archetype.zig");
    _ = @import("core/component.zig");
    _ = @import("core/entity.zig");
    _ = @import("core/event_id.zig");
    _ = @import("core/lifecycle.zig");
    _ = @import("core/world.zig");
    _ = @import("erasure/deinit.zig");
    _ = @import("erasure/hash.zig");
    _ = @import("erasure/parameter.zig");
    _ = @import("erasure/system_entry.zig");
    _ = @import("erasure/value.zig");
    _ = @import("error.zig");
    _ = @import("params/entities.zig");
    _ = @import("params/observers.zig");
    _ = @import("params/one_shots.zig");
    _ = @import("params/plugins.zig");
    _ = @import("params/resources.zig");
    _ = @import("params/systems.zig");
    _ = @import("params/views/event.zig");
    _ = @import("params/views/query.zig");
    _ = @import("params/views/resource.zig");
    _ = @import("plugins/one_shots.zig");
    _ = @import("utils.zig");
}
