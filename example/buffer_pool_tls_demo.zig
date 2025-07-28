const std = @import("std");
const tls = @import("tls");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create arena pool for handshake operations
    var arena_pool = try tls.ArenaPool.init(allocator, 4, 16 * 1024);
    defer arena_pool.deinit();

    // Create buffer pool for encrypt/decrypt operations
    var buffer_pool = try tls.BufferPool.init(allocator, 8, tls.max_ciphertext_record_len);
    defer buffer_pool.deinit();

    // Buffer pool is created with initial buffers

    std.debug.print("Buffer pool initialized with {} pre-allocated buffers\n", .{buffer_pool.stats.total_allocated});

    // Connect to a TLS server
    const host = "example.com";
    const port = 443;

    const address_list = try std.net.getAddressList(allocator, host, port);
    defer address_list.deinit();

    const addr = address_list.addrs[0];
    const stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();

    std.debug.print("Connected to {s}:{d}\n", .{ host, port });

    // Perform TLS handshake with buffer pool
    var conn = try tls.clientWithPools(stream, .{
        .host = host,
        .root_ca = try tls.config.cert.fromSystem(allocator),
    }, &arena_pool, &buffer_pool);

    std.debug.print("TLS handshake completed\n", .{});

    // Send HTTP request using the connection with buffer pool
    const request = "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n";
    try conn.writeAll(request);

    std.debug.print("HTTP request sent\n", .{});

    // Read response
    var response_buf: [4096]u8 = undefined;
    var total_read: usize = 0;

    while (true) {
        const n = try conn.read(response_buf[total_read..]);
        if (n == 0) break;
        total_read += n;
    }

    std.debug.print("Received {} bytes\n", .{total_read});

    // Print first line of response
    if (std.mem.indexOf(u8, response_buf[0..total_read], "\r\n")) |end| {
        std.debug.print("Response: {s}\n", .{response_buf[0..end]});
    }

    // Print buffer pool statistics
    std.debug.print("\nBuffer pool statistics:\n", .{});
    std.debug.print("  Total allocated: {}\n", .{buffer_pool.stats.total_allocated});
    std.debug.print("  Active buffers: {}\n", .{buffer_pool.stats.active_count});
    std.debug.print("  Peak active: {}\n", .{buffer_pool.stats.peak_active});
    std.debug.print("  Total acquires: {}\n", .{buffer_pool.stats.total_acquires});
    std.debug.print("  Cache hits: {}\n", .{buffer_pool.stats.cache_hits});
    std.debug.print("  Cache misses: {}\n", .{buffer_pool.stats.cache_misses});

    // Close connection
    try conn.close();
}