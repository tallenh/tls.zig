const std = @import("std");
const builtin = @import("builtin");

/// Optimized signal pipe for event-driven TLS buffer notifications
/// Uses atomic operations to minimize syscalls and edge-triggered signaling
pub const SignalPipe = struct {
    // File descriptors for the pipe
    read_fd: i32 = -1,
    write_fd: i32 = -1,
    
    // Atomic state tracking to minimize syscalls
    // 0 = no signal, 1 = signal pending, 2 = signal sent
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    
    // Track if we're using edge-triggered mode (Linux epoll)
    edge_triggered: bool = false,
    
    const Self = @This();
    
    /// Initialize the signal pipe with optimizations
    pub fn init() !Self {
        var pipe_fds: [2]i32 = undefined;
        
        // Platform-specific optimized pipe creation
        const edge_triggered = switch (builtin.os.tag) {
            .linux => blk: {
                // Try to create pipe2 with O_NONBLOCK and O_CLOEXEC on Linux
                const O_NONBLOCK = 0x800;
                const O_CLOEXEC = 0x80000;
                if (std.c.pipe2(&pipe_fds, O_NONBLOCK | O_CLOEXEC) == 0) {
                    break :blk true;
                }
                break :blk false;
            },
            .macos, .ios, .tvos, .watchos => blk: {
                // macOS/Darwin systems support edge-triggered via kqueue EV_CLEAR
                break :blk true;
            },
            .freebsd, .netbsd, .dragonfly => blk: {
                // BSD systems also support kqueue with EV_CLEAR
                break :blk true;
            },
            else => false,
        };
        
        // Create pipe if not already created
        if (!edge_triggered or builtin.os.tag != .linux) {
            if (std.c.pipe(&pipe_fds) != 0) {
                return error.PipeCreationFailed;
            }
            
            // Make non-blocking
            const O_NONBLOCK = if (builtin.os.tag == .macos) 0x0004 else 0x04;
            _ = std.c.fcntl(pipe_fds[0], std.c.F.SETFL, 
                std.c.fcntl(pipe_fds[0], std.c.F.GETFL) | O_NONBLOCK);
            _ = std.c.fcntl(pipe_fds[1], std.c.F.SETFL, 
                std.c.fcntl(pipe_fds[1], std.c.F.GETFL) | O_NONBLOCK);
        }
        
        return Self{
            .read_fd = pipe_fds[0],
            .write_fd = pipe_fds[1],
            .edge_triggered = edge_triggered,
        };
    }
    
    /// Deinitialize and close the pipe
    pub fn deinit(self: *Self) void {
        if (self.read_fd != -1) {
            _ = std.c.close(self.read_fd);
            self.read_fd = -1;
        }
        if (self.write_fd != -1) {
            _ = std.c.close(self.write_fd);
            self.write_fd = -1;
        }
    }
    
    /// Get the file descriptor for polling/epoll
    pub fn getFd(self: *const Self) i32 {
        return self.read_fd;
    }
    
    /// Signal that data is available (optimized with atomics)
    pub fn signal(self: *Self) void {
        // Use compare-and-swap to transition from 0 (no signal) to 1 (pending)
        const prev = self.state.cmpxchgWeak(0, 1, .monotonic, .monotonic) orelse return;
        
        // If we successfully transitioned to pending, send the signal
        if (prev == 0) {
            const signal_byte = [_]u8{1};
            _ = std.c.write(self.write_fd, &signal_byte, 1);
            
            // Mark as sent
            self.state.store(2, .release);
        }
    }
    
    /// Clear the signal (optimized for edge-triggered mode)
    pub fn clear(self: *Self) void {
        // Reset state atomically
        const prev = self.state.swap(0, .acquire);
        
        // Only drain if we had sent a signal
        if (prev == 2) {
            // For edge-triggered mode, we need to drain completely
            if (self.edge_triggered) {
                var drain_buf: [256]u8 = undefined;
                while (std.c.read(self.read_fd, &drain_buf, drain_buf.len) > 0) {}
            } else {
                // For level-triggered, a single read is sufficient
                var byte: [1]u8 = undefined;
                _ = std.c.read(self.read_fd, &byte, 1);
            }
        }
    }
    
    /// Check if a signal is pending (without blocking)
    pub fn isPending(self: *const Self) bool {
        return self.state.load(.acquire) != 0;
    }
    
    /// Enable edge-triggered mode for epoll/kqueue
    pub fn setEdgeTriggered(self: *Self, enabled: bool) void {
        self.edge_triggered = enabled;
    }
    
    /// Get platform-specific flags for epoll/kqueue registration
    pub fn getEventFlags(self: *const Self) PlatformEventFlags {
        return switch (builtin.os.tag) {
            .linux => .{
                .epoll = .{
                    // EPOLLIN with optional EPOLLET for edge-triggered
                    .events = 0x001 | (if (self.edge_triggered) @as(u32, 1 << 31) else 0),
                },
            },
            .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly => .{
                .kqueue = .{
                    // EV_ADD | EV_ENABLE with optional EV_CLEAR for edge-triggered
                    .flags = 0x0001 | 0x0004 | (if (self.edge_triggered) @as(u16, 0x0020) else 0),
                    .filter = -1, // EVFILT_READ
                },
            },
            else => .{ .generic = {} },
        };
    }
    
    /// Platform-specific event flags
    pub const PlatformEventFlags = union(enum) {
        epoll: struct {
            events: u32,
        },
        kqueue: struct {
            flags: u16,
            filter: i16,
        },
        generic: void,
    };
};

/// Compile-time optional signal pipe wrapper
pub fn OptionalSignalPipe(comptime enabled: bool) type {
    if (enabled) {
        return SignalPipe;
    } else {
        // Null implementation when disabled
        return struct {
            pub fn init() !@This() {
                return .{};
            }
            
            pub fn deinit(_: *@This()) void {}
            
            pub fn getFd(_: *const @This()) i32 {
                return -1;
            }
            
            pub fn signal(_: *@This()) void {}
            
            pub fn clear(_: *@This()) void {}
            
            pub fn isPending(_: *const @This()) bool {
                return false;
            }
            
            pub fn setEdgeTriggered(_: *@This(), _: bool) void {}
            
            pub fn getEventFlags(_: *const @This()) SignalPipe.PlatformEventFlags {
                return .{ .generic = {} };
            }
        };
    }
}

const testing = std.testing;

test "signal pipe basic operations" {
    var pipe = try SignalPipe.init();
    defer pipe.deinit();
    
    try testing.expect(pipe.getFd() >= 0);
    try testing.expect(!pipe.isPending());
    
    // Test signaling
    pipe.signal();
    try testing.expect(pipe.isPending());
    
    // Test clearing
    pipe.clear();
    try testing.expect(!pipe.isPending());
}

test "signal pipe atomic deduplication" {
    var pipe = try SignalPipe.init();
    defer pipe.deinit();
    
    // Multiple signals should only result in one write
    pipe.signal();
    pipe.signal();
    pipe.signal();
    
    try testing.expect(pipe.isPending());
    
    // Clear once should be sufficient
    pipe.clear();
    try testing.expect(!pipe.isPending());
}

test "optional signal pipe compile-time disable" {
    const DisabledPipe = OptionalSignalPipe(false);
    var pipe = try DisabledPipe.init();
    defer pipe.deinit();
    
    try testing.expectEqual(@as(i32, -1), pipe.getFd());
    try testing.expect(!pipe.isPending());
    
    // These should be no-ops
    pipe.signal();
    pipe.clear();
    pipe.setEdgeTriggered(true);
}