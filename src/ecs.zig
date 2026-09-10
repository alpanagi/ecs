pub const World = @import("core/world.zig").World;

pub const parameters = struct {
    pub const Event = @import("modules/observers/module.zig").Event;
    pub const Events = @import("modules/observers/module.zig").Events;
    pub const Observers = @import("modules/observers/module.zig").Observers;
    pub const OneShots = @import("modules/one_shots/module.zig").OneShots;
    pub const Resource = @import("modules/resources/module.zig").Resource;
    pub const Resources = @import("modules/resources/module.zig").Resources;
    pub const Systems = @import("modules/systems/module.zig").Systems;
};

test {
    @import("std").testing.refAllDecls(@This());
}
