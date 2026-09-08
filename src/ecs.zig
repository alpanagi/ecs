pub const World = @import("core/world.zig").World;

pub const parameters = struct {
    pub const Resource = @import("modules/resources/module.zig").Resource;
    pub const Resources = @import("modules/resources/module.zig").Resources;
    pub const Systems = @import("modules/systems/module.zig").Systems;
};

test {
    @import("std").testing.refAllDecls(@This());
}
