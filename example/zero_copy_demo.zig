const std = @import("std");
const tls = @import("tls");

pub fn main() !void {
    std.debug.print("=== Zero-Copy TLS Decryption Demo ===\n\n", .{});
    
    // For demo purposes, we'll simulate having ciphers from a completed handshake
    // In real usage, these would come from client() or server() functions
    std.debug.print("Note: This demo shows zero-copy concepts without a full TLS handshake\n\n", .{});
    
    // Test 1: Basic zero-copy with same buffer
    {
        std.debug.print("--- Test 1: In-place decryption (same buffer) ---\n", .{});
        
        // Create NonBlock connection with zero-copy enabled
        var conn = tls.nonblock.Connection.initWithZeroCopy(server_cipher, .{
            .in_place = true,
            .alignment = 1, // No alignment requirement for this test
        });
        
        // Create test data
        const cleartext = "Hello, zero-copy TLS!";
        var buffer: [1024]u8 = undefined;
        
        // Encrypt data
        var encrypt_conn = tls.nonblock.Connection.init(client_cipher);
        const encrypt_result = try encrypt_conn.encrypt(cleartext, &buffer);
        
        std.debug.print("Encrypted {} bytes -> {} bytes\n", .{
            cleartext.len,
            encrypt_result.ciphertext.len,
        });
        
        // Decrypt in-place (ciphertext and cleartext use same buffer)
        const decrypt_result = try conn.decrypt(
            encrypt_result.ciphertext,
            buffer[0..encrypt_result.ciphertext.len], // Same buffer!
        );
        
        std.debug.print("Decrypted {} bytes (in-place)\n", .{decrypt_result.cleartext.len});
        std.debug.print("Cleartext: {s}\n", .{decrypt_result.cleartext});
        
        // Check statistics
        if (conn.zero_copy_processor) |*zcp| {
            const stats = zcp.getStats();
            std.debug.print("Zero-copy stats: {} in-place, {} copies, {} bytes saved\n", .{
                stats.in_place_decrypts,
                stats.copy_decrypts,
                stats.total_bytes_saved,
            });
        }
    }
    
    // Test 2: Multiple records
    {
        std.debug.print("\n--- Test 2: Multiple records ---\n", .{});
        
        var conn = tls.nonblock.Connection.initWithZeroCopy(server_cipher, .{});
        
        // Large message that spans multiple TLS records
        var large_msg: [20000]u8 = undefined;
        for (0..large_msg.len) |i| {
            large_msg[i] = @truncate(i);
        }
        
        var buffer: [25000]u8 = undefined;
        
        // Encrypt
        var encrypt_conn = tls.nonblock.Connection.init(client_cipher);
        const encrypt_result = try encrypt_conn.encrypt(&large_msg, &buffer);
        
        const records = encrypt_result.ciphertext.len / tls.max_ciphertext_record_len;
        std.debug.print("Encrypted {} bytes into ~{} records\n", .{
            large_msg.len,
            records,
        });
        
        // Decrypt in-place
        const decrypt_result = try conn.decrypt(
            encrypt_result.ciphertext,
            buffer[0..encrypt_result.ciphertext.len],
        );
        
        std.debug.print("Decrypted {} bytes\n", .{decrypt_result.cleartext.len});
        
        // Verify data
        if (std.mem.eql(u8, large_msg[0..decrypt_result.cleartext.len], decrypt_result.cleartext)) {
            std.debug.print("✓ Data verified correctly\n", .{});
        } else {
            std.debug.print("✗ Data verification failed\n", .{});
        }
        
        if (conn.zero_copy_processor) |*zcp| {
            const stats = zcp.getStats();
            std.debug.print("Zero-copy stats: {} in-place, {} copies, {} bytes saved\n", .{
                stats.in_place_decrypts,
                stats.copy_decrypts,
                stats.total_bytes_saved,
            });
        }
    }
    
    // Test 3: Performance comparison
    {
        std.debug.print("\n--- Test 3: Performance comparison ---\n", .{});
        
        const iterations = 10000;
        const msg_size = 4096;
        var msg: [msg_size]u8 = undefined;
        std.crypto.random.bytes(&msg);
        
        var buffer: [msg_size + 256]u8 = undefined;
        
        // Prepare encrypted data
        var encrypt_conn = tls.nonblock.Connection.init(client_cipher);
        const encrypt_result = try encrypt_conn.encrypt(&msg, &buffer);
        
        // Test with zero-copy
        var zero_copy_conn = tls.nonblock.Connection.initWithZeroCopy(server_cipher, .{});
        const start_zc = std.time.nanoTimestamp();
        
        for (0..iterations) |_| {
            _ = try zero_copy_conn.decrypt(
                encrypt_result.ciphertext,
                buffer[0..encrypt_result.ciphertext.len],
            );
        }
        
        const elapsed_zc = std.time.nanoTimestamp() - start_zc;
        
        // Test without zero-copy
        var regular_conn = tls.nonblock.Connection.init(server_cipher);
        var separate_buf: [msg_size + 256]u8 = undefined;
        const start_reg = std.time.nanoTimestamp();
        
        for (0..iterations) |_| {
            _ = try regular_conn.decrypt(
                encrypt_result.ciphertext,
                &separate_buf,
            );
        }
        
        const elapsed_reg = std.time.nanoTimestamp() - start_reg;
        
        std.debug.print("Zero-copy: {d:.2} ns/op\n", .{
            @as(f64, @floatFromInt(elapsed_zc)) / @as(f64, iterations),
        });
        std.debug.print("Regular:   {d:.2} ns/op\n", .{
            @as(f64, @floatFromInt(elapsed_reg)) / @as(f64, iterations),
        });
        std.debug.print("Speedup:   {d:.2}x\n", .{
            @as(f64, @floatFromInt(elapsed_reg)) / @as(f64, @floatFromInt(elapsed_zc)),
        });
        
        if (zero_copy_conn.zero_copy_processor) |*zcp| {
            const stats = zcp.getStats();
            std.debug.print("Total bytes saved: {} MB\n", .{
                stats.total_bytes_saved / (1024 * 1024),
            });
        }
    }
}