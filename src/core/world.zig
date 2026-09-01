const std = @import("std");
const setup_function_protocol = @import("protocols/setup_function.zig");

const Box = @import("../utils/box.zig").Box;
const ContextId = @import("../modules/contexts/module.zig").ContextId;

pub const World = struct {
    contexts: std.AutoHashMapUnmanaged(ContextId, Box) = .empty,

    pub fn init() World {
        return World{};
    }

    pub fn deinit(self: *World, allocator: std.mem.Allocator) void {
        var it = self.contexts.valueIterator();
        while (it.next()) |box| box.deinit(allocator);
        self.contexts.deinit(allocator);
    }

    pub fn addModule(world: *World, allocator: std.mem.Allocator, setup_function: anytype) void {
        const SetupFunctionType = @TypeOf(setup_function);

        if (comptime !setup_function_protocol.validate(SetupFunctionType))
            @compileError("Does not implement SetupFunction protocol: " ++ @typeName(
                SetupFunctionType,
            ));

        var arguments: std.meta.ArgsTuple(SetupFunctionType) = undefined;
        inline for (&arguments) |*argument| {
            const ArgumentType = @TypeOf(argument.*);

            if (ArgumentType == std.mem.Allocator) {
                argument.* = allocator;
                continue;
            }

            argument.* = ArgumentType.fromWorld(allocator, world);
        }

        @call(.auto, setup_function, arguments);
    }
};

test "deinit: calls the box's deinit" {
    const allocator = std.testing.allocator;

    var world = World.init();
    defer world.deinit(allocator);

    const Context = struct { data: u32 };
    const context = try allocator.create(Context);
    context.* = .{ .data = 11 };

    try world.contexts.put(allocator, ContextId.fromType(Context), Box.fromOwnedPointer(context));
}

test "addModule: runs valid setup function with initialized parameters" {
    const TestState = struct {
        var parameter_from_world_calls: u32 = 0;
        var setup_function_calls: u32 = 0;
    };

    const Parameter = struct {
        data: u32,

        pub fn fromWorld(_: std.mem.Allocator, _: *World) @This() {
            TestState.parameter_from_world_calls += 1;

            return .{ .data = 11 };
        }
    };

    const setup_function = struct {
        pub fn function(_: std.mem.Allocator, _: Parameter) void {
            TestState.setup_function_calls += 1;
        }
    }.function;

    const allocator = std.testing.allocator;

    var world = World.init();
    defer world.deinit(allocator);

    world.addModule(allocator, setup_function);

    try std.testing.expectEqual(1, TestState.parameter_from_world_calls);
    try std.testing.expectEqual(1, TestState.setup_function_calls);
}
