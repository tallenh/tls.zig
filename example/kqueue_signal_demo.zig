const std = @import("std");
const builtin = @import("builtin");
const tls = @import("tls");

// Platform-specific imports
const c = std.c;
const os = std.os;

pub fn main() !void {
    if (builtin.os.tag != .macos and builtin.os.tag != .freebsd) {
        std.debug.print("This demo requires macOS or FreeBSD (kqueue support)\n", .{});
        return;
    }
    
    std.debug.print("=== kqueue Signal Pipe Demo (macOS/BSD) ===\n\n", .{});
    
    // Create the signal pipe
    var pipe = try tls.SignalPipe.init();
    defer pipe.deinit();
    
    std.debug.print("Signal pipe created, fd={}, edge_triggered={}\n", .{
        pipe.getFd(),
        pipe.edge_triggered,
    });
    
    // Create kqueue
    const kq = try std.posix.kqueue();
    defer std.posix.close(kq);
    
    std.debug.print("kqueue created, fd={}\n", .{kq});
    
    // Get platform-specific event flags
    const event_flags = pipe.getEventFlags();
    
    // Register the pipe with kqueue
    const change_event = std.posix.Kevent{
        .ident = @intCast(pipe.getFd()),
        .filter = event_flags.kqueue.filter, // EVFILT_READ
        .flags = event_flags.kqueue.flags,   // EV_ADD | EV_ENABLE | EV_CLEAR
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
    
    std.debug.print("Registering pipe with kqueue, flags=0x{x:0>4}\n", .{event_flags.kqueue.flags});
    
    _ = try std.posix.kevent(kq, &[_]std.posix.Kevent{change_event}, &[_]std.posix.Kevent{}, null);
    
    // Test 1: Basic signal/wait
    std.debug.print("\n--- Test 1: Basic signal/wait ---\n", .{});
    
    // Signal data availability
    pipe.signal();
    std.debug.print("Signaled pipe\n", .{});
    
    // Wait for event (non-blocking)
    var events: [1]std.posix.Kevent = undefined;
    const timeout = std.os.linux.timespec{ .tv_sec = 0, .tv_nsec = 0 };
    
    const n = try std.posix.kevent(kq, &[_]std.posix.Kevent{}, &events, &timeout);
    if (n > 0) {
        std.debug.print("kqueue returned {} event(s)\n", .{n});
        std.debug.print("  ident={}, filter={}, flags=0x{x:0>4}\n", .{
            events[0].ident,
            events[0].filter,
            events[0].flags,
        });
    }
    
    // Clear the signal
    pipe.clear();
    std.debug.print("Cleared signal\n", .{});
    
    // Test 2: Edge-triggered behavior
    std.debug.print("\n--- Test 2: Edge-triggered behavior ---\n", .{});
    
    // Multiple signals should coalesce
    pipe.signal();
    pipe.signal();
    pipe.signal();
    std.debug.print("Sent 3 signals (should coalesce)\n", .{});
    
    // Should get only one event
    const n2 = try std.posix.kevent(kq, &[_]std.posix.Kevent{}, &events, &timeout);
    std.debug.print("kqueue returned {} event(s)\n", .{n2});
    
    // With EV_CLEAR, we need to read all data to re-arm
    pipe.clear();
    
    // No more events until new signal
    const n3 = try std.posix.kevent(kq, &[_]std.posix.Kevent{}, &events, &timeout);
    std.debug.print("After clear, kqueue returned {} event(s) (should be 0)\n", .{n3});
    
    // Test 3: Performance measurement
    std.debug.print("\n--- Test 3: Performance ---\n", .{});
    
    const iterations = 10000;
    const start = std.time.nanoTimestamp();
    
    for (0..iterations) |_| {
        pipe.signal();
        _ = try std.posix.kevent(kq, &[_]std.posix.Kevent{}, &events, &timeout);
        pipe.clear();
    }
    
    const elapsed = std.time.nanoTimestamp() - start;
    const ns_per_cycle = @as(f64, @floatFromInt(elapsed)) / @as(f64, iterations);
    
    std.debug.print("Average signal/poll/clear cycle: {d:.2} ns\n", .{ns_per_cycle});
    std.debug.print("Cycles per second: {d:.2} million\n", .{1000.0 / ns_per_cycle});
}