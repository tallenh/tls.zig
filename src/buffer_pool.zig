const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const cipher = @import("cipher.zig");

/// Buffer pool for efficient memory reuse in encrypt/decrypt operations
pub const BufferPool = struct {
    const Buffer = struct {
        data: []u8,
        in_use: bool = false,
        generation: u32 = 0, // For debugging double-free issues
    };

    allocator: mem.Allocator,
    buffers: std.ArrayList(Buffer),
    buffer_size: usize,
    mutex: std.Thread.Mutex = .{},
    stats: Statistics = .{},

    pub const Statistics = struct {
        allocations: u64 = 0,
        deallocations: u64 = 0,
        hits: u64 = 0,
        misses: u64 = 0,
        active_buffers: u32 = 0,
        peak_buffers: u32 = 0,
    };

    /// Initialize buffer pool with pre-allocated buffers
    pub fn init(allocator: mem.Allocator, initial_count: usize, buffer_size: usize) !BufferPool {
        var buffers = std.ArrayList(Buffer).init(allocator);
        errdefer {
            for (buffers.items) |buf| {
                allocator.free(buf.data);
            }
            buffers.deinit();
        }

        // Pre-allocate buffers
        try buffers.ensureTotalCapacity(initial_count);
        for (0..initial_count) |_| {
            const data = try allocator.alloc(u8, buffer_size);
            try buffers.append(.{ .data = data });
        }

        return .{
            .allocator = allocator,
            .buffers = buffers,
            .buffer_size = buffer_size,
        };
    }

    pub fn deinit(self: *BufferPool) void {
        for (self.buffers.items) |buf| {
            self.allocator.free(buf.data);
        }
        self.buffers.deinit();
    }

    /// Acquire a buffer from the pool
    pub fn acquire(self: *BufferPool) !PooledBuffer {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Look for available buffer
        for (self.buffers.items) |*buf| {
            if (!buf.in_use) {
                buf.in_use = true;
                buf.generation +%= 1;
                self.stats.hits += 1;
                self.stats.active_buffers += 1;
                self.stats.peak_buffers = @max(self.stats.peak_buffers, self.stats.active_buffers);
                return PooledBuffer{
                    .pool = self,
                    .data = buf.data,
                    .generation = buf.generation,
                };
            }
        }

        // Allocate new buffer if none available
        self.stats.misses += 1;
        self.stats.allocations += 1;
        const data = try self.allocator.alloc(u8, self.buffer_size);
        const buf = try self.buffers.addOne();
        buf.* = .{
            .data = data,
            .in_use = true,
            .generation = 1,
        };
        self.stats.active_buffers += 1;
        self.stats.peak_buffers = @max(self.stats.peak_buffers, self.stats.active_buffers);
        
        return PooledBuffer{
            .pool = self,
            .data = data,
            .generation = 1,
        };
    }

    /// Return a buffer to the pool
    fn release(self: *BufferPool, data: []u8, generation: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.buffers.items) |*buf| {
            if (buf.data.ptr == data.ptr) {
                assert(buf.in_use);
                assert(buf.generation == generation); // Detect double-free
                buf.in_use = false;
                self.stats.deallocations += 1;
                self.stats.active_buffers -= 1;
                return;
            }
        }
        unreachable; // Buffer not from this pool
    }

    /// Get pool statistics
    pub fn getStats(self: *BufferPool) Statistics {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }
};

/// RAII wrapper for pooled buffer
pub const PooledBuffer = struct {
    pool: *BufferPool,
    data: []u8,
    generation: u32,

    pub fn deinit(self: PooledBuffer) void {
        self.pool.release(self.data, self.generation);
    }

    pub fn slice(self: PooledBuffer) []u8 {
        return self.data;
    }
};

/// Thread-local buffer pool for single-threaded performance
pub const ThreadLocalPool = struct {
    const max_cached = 8;
    
    buffers: [max_cached]?[]u8 = [_]?[]u8{null} ** max_cached,
    count: usize = 0,
    buffer_size: usize,
    allocator: mem.Allocator,
    fallback_pool: ?*BufferPool = null,

    pub fn init(allocator: mem.Allocator, buffer_size: usize) ThreadLocalPool {
        return .{
            .allocator = allocator,
            .buffer_size = buffer_size,
        };
    }

    pub fn deinit(self: *ThreadLocalPool) void {
        for (0..self.count) |i| {
            if (self.buffers[i]) |buf| {
                self.allocator.free(buf);
            }
        }
        self.* = undefined;
    }

    pub fn acquire(self: *ThreadLocalPool) ![]u8 {
        // Fast path: get from cache
        if (self.count > 0) {
            self.count -= 1;
            return self.buffers[self.count].?;
        }

        // Slow path: allocate new
        return try self.allocator.alloc(u8, self.buffer_size);
    }

    pub fn release(self: *ThreadLocalPool, buffer: []u8) void {
        assert(buffer.len == self.buffer_size);
        
        // Return to cache if space available
        if (self.count < max_cached) {
            self.buffers[self.count] = buffer;
            self.count += 1;
        } else {
            // Cache full, free the buffer
            self.allocator.free(buffer);
        }
    }
};

/// Global buffer pool for cipher operations
var global_pool: ?BufferPool = null;
var global_pool_mutex: std.Thread.Mutex = .{};

pub fn initGlobalPool(allocator: mem.Allocator) !void {
    global_pool_mutex.lock();
    defer global_pool_mutex.unlock();

    if (global_pool == null) {
        // Default: 16 buffers, max ciphertext size each
        global_pool = try BufferPool.init(allocator, 16, cipher.max_ciphertext_record_len);
    }
}

pub fn deinitGlobalPool() void {
    global_pool_mutex.lock();
    defer global_pool_mutex.unlock();

    if (global_pool) |*pool| {
        pool.deinit();
        global_pool = null;
    }
}

pub fn acquireGlobalBuffer() !PooledBuffer {
    global_pool_mutex.lock();
    defer global_pool_mutex.unlock();

    if (global_pool) |*pool| {
        return pool.acquire();
    }
    return error.GlobalPoolNotInitialized;
}