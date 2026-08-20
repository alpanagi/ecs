const std = @import("std");

const DeinitFunction = @import("../erasure/deinit.zig").DeinitFunction;
const getDeinitFunction = @import("../erasure/deinit.zig").getDeinitFunction;
const hash = @import("../erasure/hash.zig").hash;

pub fn componentId(comptime T: type) u64 {
    return hash(T);
}

pub fn componentTypes(comptime Components: type) []const type {
    comptime var result: []const type = &.{};
    for (std.meta.fields(Components)) |field| result = result ++ [_]type{field.type};
    return result;
}

pub fn ComponentPointers(comptime components: []const type) type {
    comptime var pointer_types: [components.len]type = undefined;
    inline for (components, 0..) |component, index| pointer_types[index] = *component;
    return @Tuple(&pointer_types);
}

pub const ComponentDescriptor = struct {
    id: u64,
    size: u32,
    alignment: u32,
    deinit: DeinitFunction,

    pub fn from(comptime T: type) ComponentDescriptor {
        return .{
            .id = componentId(T),
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
            .deinit = getDeinitFunction(T),
        };
    }

    pub fn lessThan(_: void, a: ComponentDescriptor, b: ComponentDescriptor) bool {
        return a.id < b.id;
    }

    pub fn orderById(id: u64, component: ComponentDescriptor) std.math.Order {
        return std.math.order(id, component.id);
    }
};

pub const ComponentData = struct {
    id: u64,
    bytes: ?[]const u8,
};

test "componentId: distinguishes types with identical fields" {
    const First = struct { value: u32 };
    const Second = struct { value: u32 };

    try std.testing.expect(componentId(First) != componentId(Second));
}

test "componentTypes: returns the field types of a tuple in order" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const types = comptime componentTypes(@TypeOf(.{ Position{ .x = 0, .y = 0 }, Velocity{ .dx = 0, .dy = 0 } }));

    try std.testing.expectEqual(2, types.len);
    try std.testing.expect(types[0] == Position);
    try std.testing.expect(types[1] == Velocity);
}

test "componentTypes: returns an empty list for an empty tuple" {
    try std.testing.expectEqual(0, componentTypes(@TypeOf(.{})).len);
}

test "componentTypes: keeps a type that appears more than once" {
    const Position = struct { x: f32, y: f32 };

    const types = comptime componentTypes(@TypeOf(.{ Position{ .x = 0, .y = 0 }, Position{ .x = 1, .y = 1 } }));

    try std.testing.expectEqual(2, types.len);
    try std.testing.expect(types[0] == Position);
    try std.testing.expect(types[1] == Position);
}

test "ComponentPointers: builds a tuple of pointers in the requested order" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const Pointers = ComponentPointers(&.{ Position, Velocity });
    const fields = comptime std.meta.fields(Pointers);

    try std.testing.expectEqual(2, fields.len);
    try std.testing.expect(fields[0].type == *Position);
    try std.testing.expect(fields[1].type == *Velocity);
}

test "ComponentPointers: aliases the values it points at" {
    const Position = struct { x: f32, y: f32 };

    var position = Position{ .x = 1, .y = 2 };
    const pointers: ComponentPointers(&.{Position}) = .{&position};

    pointers[0].x = 10;

    try std.testing.expectEqual(@as(f32, 10), position.x);
}

test "ComponentPointers: is empty for no components" {
    try std.testing.expectEqual(0, std.meta.fields(ComponentPointers(&.{})).len);
}

test "from: captures the id, size and alignment of the type" {
    const Position = struct { x: f32, y: f32 };

    const descriptor = ComponentDescriptor.from(Position);

    try std.testing.expectEqual(componentId(Position), descriptor.id);
    try std.testing.expectEqual(@sizeOf(Position), descriptor.size);
    try std.testing.expectEqual(@alignOf(Position), descriptor.alignment);
}

test "from: reports a marker component as zero sized" {
    const Player = struct {};

    const descriptor = ComponentDescriptor.from(Player);

    try std.testing.expectEqual(0, descriptor.size);
    try std.testing.expect(descriptor.alignment > 0);
}

test "from: gives a size that is a multiple of the alignment" {
    const Padded = struct { flag: bool, value: u64 };

    const descriptor = ComponentDescriptor.from(Padded);

    try std.testing.expectEqual(0, descriptor.size % descriptor.alignment);
}

test "from: captures a deinit that frees the component's memory" {
    const Owning = struct {
        buffer: []u8,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
        }
    };

    const allocator = std.testing.allocator;
    var owning = Owning{ .buffer = try allocator.alloc(u8, 8) };

    ComponentDescriptor.from(Owning).deinit(allocator, &owning);
}

test "from: captures a deinit that does nothing for a type without one" {
    const Position = struct { x: f32, y: f32 };

    var position = Position{ .x = 1, .y = 2 };
    ComponentDescriptor.from(Position).deinit(std.testing.allocator, &position);

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position);
}

test "lessThan: orders descriptors by ascending id" {
    const First = struct { value: u32 };
    const Second = struct { value: u64 };

    const first = ComponentDescriptor.from(First);
    const second = ComponentDescriptor.from(Second);

    const lower = if (first.id < second.id) first else second;
    const higher = if (first.id < second.id) second else first;

    try std.testing.expect(ComponentDescriptor.lessThan({}, lower, higher));
    try std.testing.expect(!ComponentDescriptor.lessThan({}, higher, lower));
    try std.testing.expect(!ComponentDescriptor.lessThan({}, first, first));
}

test "orderById: compares an id against a descriptor" {
    const Position = struct { x: f32, y: f32 };

    const descriptor = ComponentDescriptor.from(Position);

    try std.testing.expectEqual(.eq, ComponentDescriptor.orderById(descriptor.id, descriptor));
    try std.testing.expectEqual(.lt, ComponentDescriptor.orderById(descriptor.id - 1, descriptor));
    try std.testing.expectEqual(.gt, ComponentDescriptor.orderById(descriptor.id + 1, descriptor));
}

test "orderById: finds a descriptor through binarySearch" {
    const First = struct { value: u32 };
    const Second = struct { value: u64 };
    const Missing = struct { value: u8 };

    var descriptors = [_]ComponentDescriptor{
        ComponentDescriptor.from(First),
        ComponentDescriptor.from(Second),
    };
    std.sort.pdq(ComponentDescriptor, &descriptors, {}, ComponentDescriptor.lessThan);

    const found = std.sort.binarySearch(
        ComponentDescriptor,
        &descriptors,
        ComponentDescriptor.from(Second).id,
        ComponentDescriptor.orderById,
    ) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(ComponentDescriptor.from(Second).id, descriptors[found].id);
    try std.testing.expectEqual(null, std.sort.binarySearch(
        ComponentDescriptor,
        &descriptors,
        ComponentDescriptor.from(Missing).id,
        ComponentDescriptor.orderById,
    ));
}
