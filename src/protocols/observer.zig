const event_view_protocol = @import("event_view.zig");

pub fn validate(comptime Function: type) bool {
    const info = switch (@typeInfo(Function)) {
        .@"fn" => |function| function,
        else => return false,
    };

    if (info.return_type != void) return false;

    comptime var seen = false;
    inline for (info.params) |param| {
        const P = param.type orelse continue;
        if (comptime @typeInfo(P) != .@"struct") continue;
        if (comptime !event_view_protocol.validate(P)) continue;
        if (seen) return false;
        seen = true;
    }

    return true;
}
