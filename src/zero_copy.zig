const std = @import("std");
const mem = std.mem;
const cipher = @import("cipher.zig");
const record = @import("record.zig");
const proto = @import("protocol.zig");

/// Zero-copy decrypt options
pub const DecryptOptions = struct {
    /// Enable in-place decryption when possible
    in_place: bool = true,
    
    /// Minimum alignment for in-place operations
    alignment: usize = 16,
    
    /// Whether to check if buffers overlap before in-place operation
    check_overlap: bool = true,
};

/// Check if two memory regions overlap
pub fn regionsOverlap(a: []const u8, b: []const u8) bool {
    const a_start = @intFromPtr(a.ptr);
    const a_end = a_start + a.len;
    const b_start = @intFromPtr(b.ptr);
    const b_end = b_start + b.len;
    
    return !(a_end <= b_start or b_end <= a_start);
}

/// Check if in-place decryption is safe for given cipher and buffers
pub fn canDecryptInPlace(
    cipher_suite: cipher.CipherSuite,
    ciphertext: []const u8,
    output: []u8,
    options: DecryptOptions,
) bool {
    // First check if buffers are the same or overlap appropriately
    if (options.check_overlap) {
        // For in-place, we need exact same buffer or proper overlap
        if (@intFromPtr(ciphertext.ptr) != @intFromPtr(output.ptr)) {
            // If not same start, check if output is after ciphertext with no gap
            if (@intFromPtr(output.ptr) > @intFromPtr(ciphertext.ptr)) {
                const offset = @intFromPtr(output.ptr) - @intFromPtr(ciphertext.ptr);
                // For stream ciphers, we can handle small forward offsets
                if (offset > getMaxInPlaceOffset(cipher_suite)) return false;
            } else {
                // Output before ciphertext is not safe
                return false;
            }
        }
    }
    
    // Check alignment requirements
    if (options.alignment > 1) {
        if (@intFromPtr(ciphertext.ptr) % options.alignment != 0) return false;
        if (@intFromPtr(output.ptr) % options.alignment != 0) return false;
    }
    
    // Check cipher support
    return switch (cipher_suite) {
        // AEAD ciphers generally support in-place operations
        .AES_128_GCM_SHA256,
        .AES_256_GCM_SHA384,
        .CHACHA20_POLY1305_SHA256,
        .AEGIS_128L_SHA256,
        => true,
        
        // CBC modes need special handling due to padding
        .ECDHE_ECDSA_WITH_AES_128_CBC_SHA,
        .ECDHE_RSA_WITH_AES_128_CBC_SHA,
        .RSA_WITH_AES_128_CBC_SHA,
        .ECDHE_ECDSA_WITH_AES_128_CBC_SHA256,
        .ECDHE_RSA_WITH_AES_128_CBC_SHA256,
        .RSA_WITH_AES_128_CBC_SHA256,
        .ECDHE_ECDSA_WITH_AES_256_CBC_SHA384,
        .ECDHE_RSA_WITH_AES_256_CBC_SHA384,
        => false, // CBC requires more complex handling
        
        else => false,
    };
}

/// Get maximum safe offset for in-place decryption
fn getMaxInPlaceOffset(cipher_suite: cipher.CipherSuite) usize {
    return switch (cipher_suite) {
        // AEAD modes remove the auth tag, so we can handle that offset
        .AES_128_GCM_SHA256,
        .AES_256_GCM_SHA384,
        => 16, // GCM tag size
        
        .CHACHA20_POLY1305_SHA256,
        .AEGIS_128L_SHA256,
        => 16, // Poly1305/AEGIS tag size
        
        else => 0,
    };
}

/// Zero-copy TLS record processor
pub const ZeroCopyProcessor = struct {
    cipher: *cipher.Cipher,
    options: DecryptOptions,
    
    /// Statistics for monitoring
    stats: Statistics = .{},
    
    pub const Statistics = struct {
        in_place_decrypts: u64 = 0,
        copy_decrypts: u64 = 0,
        total_bytes_saved: u64 = 0,
    };
    
    const Self = @This();
    
    pub fn init(c: *cipher.Cipher, options: DecryptOptions) Self {
        return .{
            .cipher = c,
            .options = options,
        };
    }
    
    /// Decrypt a TLS record with zero-copy optimization when possible
    pub fn decryptRecord(
        self: *Self,
        ciphertext_buf: []u8, // Mutable for in-place operation
        output_buf: []u8,
        rec: record.Record,
    ) !struct {
        content_type: proto.ContentType,
        cleartext: []u8,
        in_place: bool,
    } {
        const cipher_suite = @as(cipher.CipherSuite, self.cipher.*);
        
        // Check if we can do in-place decryption
        if (self.options.in_place and 
            canDecryptInPlace(cipher_suite, rec.payload, output_buf, self.options) and
            @intFromPtr(rec.payload.ptr) == @intFromPtr(ciphertext_buf.ptr) + record.header_len) {
            
            // Attempt in-place decryption
            switch (self.cipher.*) {
                inline .AES_128_GCM_SHA256,
                .AES_256_GCM_SHA384,
                .CHACHA20_POLY1305_SHA256,
                .AEGIS_128L_SHA256,
                => |*c| {
                    // For AEAD modes in TLS 1.3, we can decrypt in-place
                    const content_type, const cleartext = try c.decryptInPlace(
                        ciphertext_buf[record.header_len..][0..rec.payload.len],
                        rec,
                    );
                    
                    self.stats.in_place_decrypts += 1;
                    self.stats.total_bytes_saved += cleartext.len;
                    
                    return .{
                        .content_type = content_type,
                        .cleartext = cleartext,
                        .in_place = true,
                    };
                },
                else => {},
            }
        }
        
        // Fall back to regular decrypt
        const content_type, const cleartext = try self.cipher.decrypt(output_buf, rec);
        self.stats.copy_decrypts += 1;
        
        return .{
            .content_type = content_type,
            .cleartext = cleartext,
            .in_place = false,
        };
    }
    
    pub fn getStats(self: *const Self) Statistics {
        return self.stats;
    }
};

/// Extend AEAD cipher types with in-place decryption
pub fn addInPlaceDecrypt(comptime CipherType: type) type {
    return struct {
        /// In-place decryption for AEAD modes
        pub fn decryptInPlace(
            self: *CipherType,
            payload_buf: []u8, // Mutable buffer containing ciphertext
            rec: record.Record,
        ) !struct { proto.ContentType, []u8 } {
            const auth_tag_len = 16; // All our AEAD modes use 16-byte tags
            const overhead = auth_tag_len + 1;
            
            if (rec.payload.len < overhead) return error.TlsDecryptError;
            const ciphertext_len = rec.payload.len - auth_tag_len;
            
            // Verify buffer is large enough and properly positioned
            if (payload_buf.len < rec.payload.len) return error.TlsCipherNoSpaceLeft;
            if (@intFromPtr(payload_buf.ptr) != @intFromPtr(rec.payload.ptr)) {
                return error.TlsInvalidBuffer;
            }
            
            const ciphertext = payload_buf[0..ciphertext_len];
            const auth_tag = payload_buf[ciphertext_len..][0..auth_tag_len];
            
            // Decrypt in-place
            const iv = self.getDecryptIV();
            const ad = rec.header;
            
            CipherType.getAeadType().decrypt(
                ciphertext, // Output overwrites input
                ciphertext, // Input
                auth_tag.*,
                ad,
                iv,
                self.decrypt_key,
            ) catch return error.TlsBadRecordMac;
            
            // Remove padding and extract content type (TLS 1.3)
            var content_type_idx: usize = ciphertext_len - 1;
            while (ciphertext[content_type_idx] == 0 and content_type_idx > 0) : (content_type_idx -= 1) {}
            
            const cleartext = ciphertext[0..content_type_idx];
            const content_type: proto.ContentType = @enumFromInt(ciphertext[content_type_idx]);
            
            self.decrypt_seq +%= 1;
            return .{ content_type, cleartext };
        }
    };
}

const testing = std.testing;

test "regions overlap detection" {
    var buf: [100]u8 = undefined;
    
    // Same buffer
    try testing.expect(regionsOverlap(&buf, &buf));
    
    // Partial overlap
    try testing.expect(regionsOverlap(buf[0..50], buf[25..75]));
    
    // No overlap
    try testing.expect(!regionsOverlap(buf[0..25], buf[50..75]));
    
    // Adjacent buffers (no overlap)
    try testing.expect(!regionsOverlap(buf[0..50], buf[50..100]));
}

test "can decrypt in place" {
    var buf: [1024]u8 align(16) = undefined;
    
    // Test same buffer
    try testing.expect(canDecryptInPlace(
        .AES_128_GCM_SHA256,
        &buf,
        &buf,
        .{},
    ));
    
    // Test unsupported cipher
    try testing.expect(!canDecryptInPlace(
        .ECDHE_RSA_WITH_AES_128_CBC_SHA,
        &buf,
        &buf,
        .{},
    ));
    
    // Test alignment
    try testing.expect(!canDecryptInPlace(
        .AES_128_GCM_SHA256,
        buf[1..], // Misaligned
        buf[1..],
        .{ .alignment = 16 },
    ));
}