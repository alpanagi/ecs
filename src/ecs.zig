pub const World = @import("world.zig").World;
pub const Entity = @import("entity.zig").Entity;
pub const Query = @import("world.zig").Query;
pub const Resource = @import("world.zig").Resource;
pub const Event = @import("system_registry.zig").Event;

pub const events = struct {
    pub const Added = @import("lifecycle.zig").Added;
    pub const Destroying = @import("lifecycle.zig").Destroying;
};