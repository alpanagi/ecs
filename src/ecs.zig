pub const World = @import("core/world.zig").World;

test {
    @import("std").testing.refAllDecls(@This());
}
