const std = @import("std");
const system_protocol = @import("protocols/system.zig");
const systems_module = @import("../modules/systems/module.zig");

const Box = @import("../utils/box.zig").Box;
const ResourceId = @import("../modules/resources/module.zig").ResourceId;

const runSystem = @import("run_system.zig").runSystem;

pub const World = struct {
    resources: std.AutoHashMapUnmanaged(ResourceId, Box) = .empty,

    pub fn init(allocator: std.mem.Allocator) World {
        var world = World{};

        world.addModule(allocator, systems_module.setup);

        return world;
    }

    pub fn deinit(self: *World, allocator: std.mem.Allocator) void {
        var it = self.resources.valueIterator();
        while (it.next()) |box| box.deinit(allocator);
        self.resources.deinit(allocator);
    }

    pub fn addModule(self: *World, allocator: std.mem.Allocator, setup_function: anytype) void {
        const SetupFunctionType = @TypeOf(setup_function);

        if (comptime !system_protocol.validate(SetupFunctionType))
            @compileError("Does not implement System protocol: " ++ @typeName(SetupFunctionType));

        runSystem(allocator, self, setup_function);
    }
};

test "deinit: calls the box's deinit" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const Type = struct { data: u32 };
    const resource = try allocator.create(Type);
    resource.* = .{ .data = 11 };

    try world.resources.put(
        allocator,
        ResourceId.fromType(Type),
        Box.fromOwnedPointer(resource),
    );
}
