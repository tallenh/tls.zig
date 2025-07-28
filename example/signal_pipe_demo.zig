const std = @import("std");
const tls = @import("tls");

pub fn main() !void {
    // Basic signal pipe usage
    {
        var pipe = try tls.SignalPipe.init();
        defer pipe.deinit();
        
        std.debug.print("Signal pipe initialized, fd={}\n", .{pipe.getFd()});
        
        // Test signaling
        std.debug.print("Signaling...\n", .{});
        pipe.signal();
        std.debug.print("Is pending: {}\n", .{pipe.isPending()});
        
        // Multiple signals are deduplicated
        pipe.signal();
        pipe.signal();
        std.debug.print("After multiple signals, still pending: {}\n", .{pipe.isPending()});
        
        // Clear the signal
        pipe.clear();
        std.debug.print("After clear, pending: {}\n", .{pipe.isPending()});
    }
    
    // Demonstrate integration with poll/epoll
    {
        std.debug.print("\n--- Poll/Epoll Integration Demo ---\n", .{});
        
        var pipe = try tls.SignalPipe.init();
        defer pipe.deinit();
        
        // Signal some data
        pipe.signal();
        
        // Use poll to check for readability
        var pollfd = std.posix.pollfd{
            .fd = pipe.getFd(),
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        
        const timeout_ms = 0; // Don't block
        var pollfds = [_]std.posix.pollfd{pollfd};
        const ready = try std.posix.poll(&pollfds, timeout_ms);
        
        if (ready > 0) {
            std.debug.print("Poll indicates data is ready (revents={x})\n", .{pollfd.revents});
        }
        
        // Clear and check again
        pipe.clear();
        pollfd.revents = 0;
        pollfds[0] = pollfd;
        const ready2 = try std.posix.poll(&pollfds, timeout_ms);
        std.debug.print("After clear, poll ready count: {}\n", .{ready2});
    }
    
    // Demonstrate compile-time optional signal pipe
    {
        std.debug.print("\n--- Compile-time Optional Demo ---\n", .{});
        
        const EnabledPipe = tls.OptionalSignalPipe(true);
        const DisabledPipe = tls.OptionalSignalPipe(false);
        
        var enabled = try EnabledPipe.init();
        defer enabled.deinit();
        
        var disabled = try DisabledPipe.init();
        defer disabled.deinit();
        
        std.debug.print("Enabled pipe fd: {}\n", .{enabled.getFd()});
        std.debug.print("Disabled pipe fd: {} (should be -1)\n", .{disabled.getFd()});
        
        // Operations on disabled pipe are no-ops
        disabled.signal();
        disabled.clear();
        std.debug.print("Disabled pipe pending: {} (should be false)\n", .{disabled.isPending()});
    }
    
    // Performance comparison
    {
        std.debug.print("\n--- Performance Comparison ---\n", .{});
        
        var pipe = try tls.SignalPipe.init();
        defer pipe.deinit();
        
        const iterations = 100_000;
        
        // Measure atomic deduplication performance
        const start = std.time.nanoTimestamp();
        
        for (0..iterations) |_| {
            pipe.signal();
            pipe.clear();
        }
        
        const elapsed = std.time.nanoTimestamp() - start;
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, iterations);
        
        std.debug.print("Average time per signal/clear cycle: {d:.2} ns\n", .{ns_per_op});
        std.debug.print("Operations per second: {d:.2} million\n", .{1000.0 / ns_per_op});
    }
}