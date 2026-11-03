const std = @import("std");
const JobSystem = @import("../../src/jobs/job_system.zig").JobSystem;
const Job = @import("../../src/jobs/job.zig").Job;

fn dummyJob(ctx: *anyopaque) void {
    _ = ctx;
}

pub fn main() !void {
    var sys = try JobSystem.init(std.heap.page_allocator);
    defer sys.deinit();

    var context: u8 = 0;
    const job = Job{ .name = "test", .func = dummyJob, .ctx = &context };
    try sys.submit(job);
    try sys.executeAll();
    std.debug.print("Job System OK\n", .{});
}
