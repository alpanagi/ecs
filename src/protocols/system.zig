pub fn validate(comptime Function: type) bool {
    const info = switch (@typeInfo(Function)) {
        .@"fn" => |function| function,
        else => return false,
    };

    return info.return_type == void;
}
