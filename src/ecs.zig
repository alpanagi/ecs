pub const World = @import("world.zig").World;
pub const Entity = @import("entity.zig").Entity;

pub const events = struct {
    pub const Added = @import("lifecycle.zig").Added;
    pub const Destroying = @import("lifecycle.zig").Destroying;
};