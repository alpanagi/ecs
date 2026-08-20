pub const World = @import("world.zig").World;
pub const Entity = @import("entity.zig").Entity;
pub const Query = @import("query.zig").Query;
pub const Commands = @import("commands.zig").Commands;
pub const Observers = @import("world.zig").Observers;
pub const Resource = @import("resource.zig").Resource;
pub const Event = @import("event.zig").Event;
pub const EventId = @import("event.zig").EventId;
pub const componentId = @import("component.zig").componentId;
pub const DeinitFunction = @import("deinit.zig").DeinitFunction;
pub const getDeinitFunction = @import("deinit.zig").getDeinitFunction;

pub const events = struct {
    pub const component = @import("lifecycle.zig").component;
    pub const resource = @import("lifecycle.zig").resource;
    pub const ComponentAdded = @import("lifecycle.zig").ComponentAdded;
    pub const ComponentDestroying = @import("lifecycle.zig").ComponentDestroying;
    pub const ResourceAdded = @import("lifecycle.zig").ResourceAdded;
    pub const ResourceDestroying = @import("lifecycle.zig").ResourceDestroying;
};
