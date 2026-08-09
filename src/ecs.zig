pub const World = @import("world.zig").World;
pub const Entity = @import("entity.zig").Entity;
pub const Query = @import("world.zig").Query;
pub const Commands = @import("world.zig").Commands;
pub const Observers = @import("world.zig").Observers;
pub const Resource = @import("world.zig").Resource;
pub const Event = @import("system_registry.zig").Event;

pub const events = struct {
    pub const component = @import("lifecycle.zig").component;
    pub const resource = @import("lifecycle.zig").resource;
};