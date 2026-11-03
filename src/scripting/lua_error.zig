const std = @import("std");

pub const LuaError = error{
    RuntimeError,
    MemoryLimitExceeded,
};
