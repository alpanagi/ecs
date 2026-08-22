const system_protocol = @import("system.zig");

pub fn validate(comptime Function: type, comptime Plugin: type) bool {
    if (!system_protocol.validate(Function)) return false;

    const info = @typeInfo(Function).@"fn";
    if (info.params.len == 0) return false;

    return info.params[0].type == *Plugin;
}
