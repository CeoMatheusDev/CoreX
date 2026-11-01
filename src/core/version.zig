const std = @import("std");

pub const VERSION_MAJOR = 0;
pub const VERSION_MINOR = 1;
pub const VERSION_PATCH = 0;
pub const VERSION_STRING = "0.1.0";

pub const Version = struct {
    major: u32 = VERSION_MAJOR,
    minor: u32 = VERSION_MINOR,
    patch: u32 = VERSION_PATCH,

    pub fn toString(self: Version, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch }) catch "0.0.0";
    }
};

