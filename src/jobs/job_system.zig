const std = @import("std");
const Job = @import("job.zig").Job;

pub const JobSystem = struct {
    allocator: std.mem.Allocator,
    count: usize = 0,
    capacity: usize = 4,
    items: []Job,

    pub fn init(allocator: std.mem.Allocator) !JobSystem {
        const cap = 4;
        const arr = try allocator.alloc(Job, cap);
        return .{
            .allocator = allocator,
            .items = arr,
            .capacity = cap,
        };
    }

    pub fn deinit(self: *JobSystem) void {
        self.allocator.free(self.items);
    }

    pub fn submit(self: *JobSystem, job: Job) !void {
        if (self.count >= self.capacity) {
            const new_cap = self.capacity * 2;
            const new_arr = try self.allocator.realloc(self.items, new_cap);
            self.items = new_arr;
            self.capacity = new_cap;
        }
        self.items[self.count] = job;
        self.count += 1;
    }

    pub fn executeAll(self: *JobSystem) void {
        for (self.items[0..self.count]) |job| {
            if (job.func != null) {
                job.func(job.ctx);
            }
        }
    }
};
