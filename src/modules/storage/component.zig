const std = @import("std");
const deinit_protocol = @import("../../utils/protocols/deinit.zig");

const ComponentId = @import("component_id.zig").ComponentId;
const DeinitFunction = @import("../../utils/deinit_function.zig").DeinitFunction;

const max_alignment: std.mem.Alignment = .@"64";

pub const Component = union(enum) {
    marker: MarkerComponent,
    sized: SizedComponent,

    pub fn fromType(Type: type) Component {
        if (@sizeOf(Type) == 0) {
            return .{ .marker = MarkerComponent{ .id = ComponentId.fromType(Type) } };
        }

        if (comptime @alignOf(Type) > max_alignment.toByteUnits())
            @compileError("Component alignment exceeds " ++ @tagName(max_alignment) ++
                ": " ++ @typeName(Type));

        const deinit = if (comptime deinit_protocol.validate(Type)) struct {
            pub fn function(value: *anyopaque, allocator: std.mem.Allocator) void {
                const typed_value: *Type = @ptrCast(@alignCast(value));
                typed_value.deinit(allocator);
            }
        }.function else null;

        return .{ .sized = SizedComponent{
            .id = ComponentId.fromType(Type),
            .size = @sizeOf(Type),
            .data = .empty,
            .deinit = deinit,
        } };
    }

    pub fn id(self: *const Component) ComponentId {
        return switch (self.*) {
            .marker => self.marker.id,
            .sized => self.sized.id,
        };
    }
};

const SizedComponent = struct {
    id: ComponentId,
    size: usize,
    data: std.ArrayListAligned(u8, max_alignment),
    deinit: ?DeinitFunction,
};

const MarkerComponent = struct {
    id: ComponentId,
};
