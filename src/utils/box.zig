const std = @import("std");
const deinit_protocol = @import("protocols/deinit.zig");
const mutable_pointer_protocol = @import("protocols/mutable_pointer.zig");

pub const Box = struct {
    value: *anyopaque,
    deinit_function: *const DeinitFunction,

    pub fn fromOwnedPointer(pointer: anytype) Box {
        const PointerType = @TypeOf(pointer);
        if (comptime !mutable_pointer_protocol.validate(PointerType))
            @compileError("Does not implement MutablePointer protocol: " ++ @typeName(PointerType));

        const ValueType = @typeInfo(PointerType).pointer.child;
        const deinit_function: *const DeinitFunction = struct {
            pub fn function(value: *anyopaque, allocator: std.mem.Allocator) void {
                const typed_value: PointerType = @ptrCast(@alignCast(value));
                if (comptime deinit_protocol.validate(ValueType)) typed_value.deinit(allocator);
                allocator.destroy(typed_value);
            }
        }.function;

        return Box{
            .value = @ptrCast(pointer),
            .deinit_function = deinit_function,
        };
    }

    pub fn deinit(self: *Box, allocator: std.mem.Allocator) void {
        self.deinit_function(self.value, allocator);
        self.* = undefined;
    }
};

const DeinitFunction = fn (*anyopaque, std.mem.Allocator) void;

test "deinit: calls deinit of inner type on deinit" {
    const allocator = std.testing.allocator;

    const TestState = struct {
        var deinit_calls: u32 = 0;
    };

    const Data = struct {
        data: u32,

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {
            TestState.deinit_calls += 1;
        }
    };

    const data = try allocator.create(Data);
    data.* = .{ .data = 11 };

    var boxed_type = Box.fromOwnedPointer(data);
    boxed_type.deinit(allocator);

    try std.testing.expectEqual(1, TestState.deinit_calls);
}

test "deinit: destroys inner type when deinit is missing" {
    const allocator = std.testing.allocator;

    const Data = struct { data: u32 };
    const data = try allocator.create(Data);
    data.* = .{ .data = 13 };

    var boxed_type = Box.fromOwnedPointer(data);
    boxed_type.deinit(allocator);
}
