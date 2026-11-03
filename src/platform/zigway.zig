// Integração CoreX ↔ Zigway
// Versão de referência: v0.1.0-alpha.4 (MIT)
// Repositório: https://github.com/CeoMatheusDev/Zigway

const std = @import("std");
const zigway = @import("zigway");

pub const Capabilities = zigway.Capabilities;
pub const ActiveBackend = zigway.ActiveBackend;
pub const Event = zigway.Event;
pub const InputState = zigway.InputState;

pub const Platform = struct {
    allocator: std.mem.Allocator,
    instance: zigway.Platform,

    /// Builds the platform using Zigway's default backend selection.
    pub fn init(allocator: std.mem.Allocator) !Platform {
        return initWithOptions(allocator, .{});
    }

    /// Explicitly configures Zigway, including its null backend for
    /// deterministic headless tests and tools. Production callers should
    /// normally use `init` to preserve Zigway's platform selection.
    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        options: zigway.PlatformOptions,
    ) !Platform {
        return .{
            .allocator = allocator,
            .instance = try zigway.Platform.init(allocator, options),
        };
    }

    pub fn deinit(self: *Platform) void {
        self.instance.deinit();
    }

    pub fn backendKind(self: *const Platform) ActiveBackend {
        return self.instance.backendKind();
    }

    pub fn createWindow(self: *Platform, config: zigway.WindowConfig) !zigway.Window {
        return self.instance.createWindow(config);
    }

    pub fn capabilities(self: *const Platform) Capabilities {
        return self.instance.capabilities();
    }

    /// Drains native events into Zigway's bounded queue.
    pub fn pollEvents(self: *Platform) void {
        self.instance.pollEvents();
    }

    /// Waits on the platform thread; `timeout_ms` is forwarded unchanged.
    pub fn waitEvents(self: *Platform, timeout_ms: i32) u32 {
        return self.instance.waitEvents(timeout_ms);
    }

    /// Consumes the next queued event, or null when the queue is empty.
    pub fn nextEvent(self: *Platform) ?Event {
        return self.instance.nextEvent();
    }

    pub fn inputState(self: *const Platform) *const InputState {
        return self.instance.inputState();
    }

    pub fn droppedEvents(self: *const Platform) u64 {
        return self.instance.droppedEvents();
    }
};
