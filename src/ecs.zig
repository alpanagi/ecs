pub const DeinitFunction = @import("erasure/deinit.zig").DeinitFunction;
pub const Entities = @import("params/entities.zig").Entities;
pub const Entity = @import("core/entity.zig").Entity;
pub const Event = @import("params/views/event.zig").Event;
pub const EventId = @import("events/event_id.zig").EventId;
pub const Observers = @import("params/observers.zig").Observers;
pub const OneShots = @import("params/one_shots.zig").OneShots;
pub const Query = @import("params/views/query.zig").Query;
pub const Resource = @import("params/views/resource.zig").Resource;
pub const Resources = @import("params/resources.zig").Resources;
pub const Systems = @import("params/systems.zig").Systems;
pub const World = @import("core/world.zig").World;

pub const componentId = @import("core/component.zig").componentId;
pub const eventId = @import("events/event_id.zig").eventId;
pub const getDeinitFunction = @import("erasure/deinit.zig").getDeinitFunction;
pub const resourceId = @import("core/resource.zig").resourceId;

pub const events = struct {
    pub const ComponentAdded = @import("events/component.zig").ComponentAdded;
    pub const ComponentDestroying = @import("events/component.zig").ComponentDestroying;
    pub const ResourceAdded = @import("events/resource.zig").ResourceAdded;
    pub const ResourceDestroying = @import("events/resource.zig").ResourceDestroying;

    pub const componentAdded = @import("events/component.zig").componentAdded;
    pub const componentDestroying = @import("events/component.zig").componentDestroying;
    pub const resourceAdded = @import("events/resource.zig").resourceAdded;
    pub const resourceDestroying = @import("events/resource.zig").resourceDestroying;
};

test {
    _ = @import("core/archetype.zig");
    _ = @import("core/component.zig");
    _ = @import("core/entity.zig");
    _ = @import("core/resource.zig");
    _ = @import("core/world.zig");
    _ = @import("erasure/deinit.zig");
    _ = @import("erasure/hash.zig");
    _ = @import("erasure/parameter.zig");
    _ = @import("erasure/system_entry.zig");
    _ = @import("erasure/value.zig");
    _ = @import("error.zig");
    _ = @import("events/component.zig");
    _ = @import("events/event_id.zig");
    _ = @import("events/resource.zig");
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
    _ = @import("protocols/deinit.zig");
    _ = @import("protocols/event.zig");
    _ = @import("protocols/event_view.zig");
    _ = @import("protocols/observer.zig");
    _ = @import("protocols/parameter.zig");
    _ = @import("protocols/plugin.zig");
    _ = @import("protocols/plugin_observer.zig");
    _ = @import("protocols/plugin_system.zig");
    _ = @import("protocols/system.zig");
    _ = @import("utils.zig");
}
