package app 


log_system_t :: struct {
    loggingName : [dynamic]u8,
    loggingPass : [dynamic]u8,
    loggingNameLen : int,
    loggingPassLen : int,
}

log_system_t_default :: proc(allocator := context.allocator) -> log_system_t {
    return log_system_t {
        loggingName = make([dynamic]u8, 0, 256, allocator),
        loggingPass = make([dynamic]u8, 0, 256, allocator),
        loggingNameLen = 0,
        loggingPassLen = 0,
    }
}