pub fn Event(Type: type) type {
    return struct { value: *const Type };
}
