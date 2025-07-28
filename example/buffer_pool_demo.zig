const std = @import("std");
const tls = @import("tls");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Example 1: Using global buffer pool
    try demonstrateGlobalPool(allocator);

    // Example 2: Using thread-local pool
    try demonstrateThreadLocalPool(allocator);

    // Example 3: Using dedicated buffer pool
    try demonstrateDedicatedPool(allocator);
}

fn demonstrateGlobalPool(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Global Buffer Pool Demo ===\n", .{});

    // Initialize global pool
    try tls.buffer_pool.initGlobalPool(allocator);
    defer tls.buffer_pool.deinitGlobalPool();

    // Simulate multiple buffer acquisitions
    var buffers: [5]tls.PooledBuffer = undefined;
    
    for (0..5) |i| {
        buffers[i] = try tls.buffer_pool.acquireGlobalBuffer();
        std.debug.print("Acquired buffer {}: {} bytes\n", .{ i, buffers[i].data.len });
        
        // Simulate using the buffer
        @memset(buffers[i].data[0..16], @intCast(i));
    }

    // Release buffers back to pool
    for (buffers) |buf| {
        buf.deinit();
    }
    
    std.debug.print("All buffers returned to pool\n", .{});
}

fn demonstrateThreadLocalPool(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Thread-Local Pool Demo ===\n", .{});

    var pool = tls.ThreadLocalPool.init(allocator, 1024);
    defer pool.deinit();

    // Fast acquire/release cycle
    var timer = try std.time.Timer.start();
    
    for (0..1000) |_| {
        const buf = try pool.acquire();
        defer pool.release(buf);
        
        // Simulate work
        @memset(buf[0..16], 0xAA);
    }
    
    const elapsed = timer.read();
    std.debug.print("1000 acquire/release cycles: {} ns\n", .{elapsed});
}

fn demonstrateDedicatedPool(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Dedicated Buffer Pool Demo ===\n", .{});

    // Create pool with 4 initial buffers of 4KB each
    var pool = try tls.BufferPool.init(allocator, 4, 4096);
    defer pool.deinit();

    // Acquire more buffers than initially allocated
    var buffers: [6]tls.PooledBuffer = undefined;
    
    for (0..6) |i| {
        buffers[i] = try pool.acquire();
        std.debug.print("Buffer {}: allocated\n", .{i});
    }

    // Get statistics
    const stats = pool.getStats();
    std.debug.print("\nPool Statistics:\n", .{});
    std.debug.print("  Hits: {}\n", .{stats.hits});
    std.debug.print("  Misses: {}\n", .{stats.misses});
    std.debug.print("  Active: {}\n", .{stats.active_buffers});
    std.debug.print("  Peak: {}\n", .{stats.peak_buffers});

    // Release all buffers
    for (buffers) |buf| {
        buf.deinit();
    }

    // Acquire again to demonstrate reuse
    std.debug.print("\nAfter releasing all buffers:\n", .{});
    const reused = try pool.acquire();
    defer reused.deinit();
    
    const stats2 = pool.getStats();
    std.debug.print("  Hits after reuse: {} (increased by 1)\n", .{stats2.hits});
}