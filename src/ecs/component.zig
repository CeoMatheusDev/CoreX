const std = @import("std");

pub fn Component(comptime T: type) type {
    return struct {
        data: T,
        entity_id: u32,
    };
}
