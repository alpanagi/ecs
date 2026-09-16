const std = @import("std");

const Component = @import("component.zig").Component;
const ComponentId = @import("component_id.zig").ComponentId;

const panic = @import("../../utils/panic.zig").panic;
const panicOom = @import("../../utils/panic.zig").panicOom;

var marker_pointer_data: u8 align(64) = 0;

pub const Archetype = struct {
    components: []Component,

    pub fn init(allocator: std.mem.Allocator, comptime component_types: []const type) Archetype {
        const components = allocator.alloc(Component, component_types.len) catch
            panicOom(@This(), @src());

        inline for (component_types, 0..) |ComponentType, index| {
            components[index] = Component.fromType(ComponentType);
        }

        std.mem.sort(Component, components, {}, struct {
            fn lessThan(_: void, a: Component, b: Component) bool {
                return @intFromEnum(a.id()) < @intFromEnum(b.id());
            }
        }.lessThan);

        return Archetype{ .components = components };
    }

    pub fn deinit(self: *Archetype, allocator: std.mem.Allocator) void {
        for (self.components) |*component| {
            if (component.* == .marker) continue;

            if (component.sized.deinit != null) {
                var offset: usize = 0;
                while (offset < component.sized.data.items.len) : (offset += component.sized.size) {
                    component.sized.deinit.?(&component.sized.data.items[offset], allocator);
                }
            }

            component.sized.data.deinit(allocator);
        }

        allocator.free(self.components);
    }

    pub fn addOwned(
        self: *Archetype,
        allocator: std.mem.Allocator,
        component_values: anytype,
    ) void {
        const error_message = "You should pass a pointer to a tuple of component values to addOwned";

        const components_info = @typeInfo(@TypeOf(component_values));
        if (components_info != .pointer or components_info.pointer.size != .one)
            @compileError(error_message);

        const child_info = @typeInfo(components_info.pointer.child);
        if (child_info != .@"struct" or !child_info.@"struct".is_tuple)
            @compileError(error_message);

        components: for (self.components) |*component| {
            if (component.* == .marker) continue;

            inline for (component_values) |component_value| {
                if (component.id() == ComponentId.fromType(@TypeOf(component_value))) {
                    component.sized.data.appendSlice(allocator, std.mem.asBytes(&component_value)) catch
                        panicOom(@This(), @src());

                    continue :components;
                }
            }
        }
    }

    pub fn getComponents(
        self: *Archetype,
        index: usize,
        comptime component_types: []const type,
    ) ComponentPointers(component_types) {
        var component_pointers: ComponentPointers(component_types) = undefined;

        inline for (component_types, 0..) |ComponentType, pointer_index| {
            const component = for (self.components) |*component| {
                if (component.id() == ComponentId.fromType(ComponentType)) break component;
            } else panic("Archetype doesn't contain component: {s}", .{@typeName(ComponentType)});

            if (comptime @sizeOf(ComponentType) == 0) {
                component_pointers[pointer_index] = @ptrCast(&marker_pointer_data);
                continue;
            }

            component_pointers[pointer_index] = @ptrCast(@alignCast(
                &component.sized.data.items[index * component.sized.size],
            ));
        }

        return component_pointers;
    }
};

fn ComponentPointers(component_types: []const type) type {
    var pointer_types: [component_types.len]type = undefined;
    for (component_types, &pointer_types) |ComponentType, *PointerType| {
        PointerType.* = *ComponentType;
    }

    return @Tuple(&pointer_types);
}

test "init: orders components" {
    const ComponentOne = struct { data: u32 };
    const ComponentTwo = struct { data: u8 };

    const allocator = std.testing.allocator;

    var archetype_one = Archetype.init(allocator, &.{ ComponentOne, ComponentTwo });
    defer archetype_one.deinit(allocator);

    var archetype_two = Archetype.init(allocator, &.{ ComponentTwo, ComponentOne });
    defer archetype_two.deinit(allocator);

    try std.testing.expectEqual(
        archetype_one.components[0].id(),
        archetype_two.components[0].id(),
    );

    try std.testing.expectEqual(
        archetype_one.components[1].id(),
        archetype_two.components[1].id(),
    );
}

test "deinit: calls the component deinit, if it exists" {
    const TestState = struct {
        var deinit_calls: u32 = 0;
    };

    const ComponentOne = struct {
        data: u32,
        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {
            TestState.deinit_calls += 1;
        }
    };
    const ComponentTwo = struct { data: u8 };

    const allocator = std.testing.allocator;
    var archetype = Archetype.init(allocator, &.{ ComponentOne, ComponentTwo });

    archetype.addOwned(allocator, &.{
        ComponentOne{ .data = 11 },
        ComponentTwo{ .data = 12 },
    });

    archetype.deinit(allocator);

    try std.testing.expectEqual(1, TestState.deinit_calls);
}

test "addOwned: copies the data to the archetype respecting component size" {
    const ComponentOne = struct { data: u32 };
    const ComponentTwo = struct { data: u8 };

    const allocator = std.testing.allocator;

    var archetype = Archetype.init(allocator, &.{ ComponentOne, ComponentTwo });
    defer archetype.deinit(allocator);

    archetype.addOwned(allocator, &.{
        ComponentOne{ .data = 13 },
        ComponentTwo{ .data = 14 },
    });

    archetype.addOwned(allocator, &.{
        ComponentOne{ .data = 15 },
        ComponentTwo{ .data = 16 },
    });

    var data = archetype.getComponents(0, &.{ ComponentOne, ComponentTwo });
    try std.testing.expectEqual(13, data[0].data);
    try std.testing.expectEqual(14, data[1].data);

    data = archetype.getComponents(1, &.{ ComponentOne, ComponentTwo });
    try std.testing.expectEqual(15, data[0].data);
    try std.testing.expectEqual(16, data[1].data);
}

test "addOwned: copies data correctly no matter the order passed" {
    const ComponentOne = struct { data: u32 };
    const ComponentTwo = struct { data: u8 };

    const allocator = std.testing.allocator;

    var archetype = Archetype.init(allocator, &.{ ComponentOne, ComponentTwo });
    defer archetype.deinit(allocator);

    archetype.addOwned(allocator, &.{
        ComponentTwo{ .data = 18 },
        ComponentOne{ .data = 17 },
    });

    archetype.addOwned(allocator, &.{
        ComponentOne{ .data = 19 },
        ComponentTwo{ .data = 20 },
    });

    var data = archetype.getComponents(0, &.{ ComponentOne, ComponentTwo });
    try std.testing.expectEqual(17, data[0].data);
    try std.testing.expectEqual(18, data[1].data);

    data = archetype.getComponents(1, &.{ ComponentOne, ComponentTwo });
    try std.testing.expectEqual(19, data[0].data);
    try std.testing.expectEqual(20, data[1].data);
}
