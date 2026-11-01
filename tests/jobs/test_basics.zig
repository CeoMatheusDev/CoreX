const std = @import("std");
const JobSystem = @import("../../src/jobs/job_system.zig").JobSystem;
const Job = @import("../../src/jobs/job.zig").Job;

fn dummyJob(ctx: *anyopaque) void {
    _ = ctx;
}

pub fn main() !void {
    var sys = try JobSystem.init(std.heap.page_allocator);
    defer sys.deinit();

    const job = Job{ .name = "test", .func = dummyJob, .ctx = null };
    try sys.submit(job);
    sys.executeAll();
    std.debug.print("Job System OK\n", .{});
}
