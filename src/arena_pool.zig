const std = @import("std");
const mem = std.mem;

/// Thread-safe arena allocator pool for handshake operations
/// Reduces allocation overhead by reusing memory during handshakes
pub const ArenaPool = struct {
    const Arena = struct {
        allocator: std.heap.ArenaAllocator,
        in_use: bool = false,
    };

    const default_arena_size = 64 * 1024; // 64KB per arena
    
    mutex: std.Thread.Mutex = .{},
    arenas: std.ArrayList(Arena),
    parent_allocator: mem.Allocator,
    arena_size: usize,

    pub fn init(allocator: mem.Allocator, initial_arenas: usize, arena_size: usize) !ArenaPool {
        var arenas = std.ArrayList(Arena).init(allocator);
        errdefer arenas.deinit();

        // Pre-allocate initial arenas
        try arenas.ensureTotalCapacity(initial_arenas);
        
        return .{
            .arenas = arenas,
            .parent_allocator = allocator,
            .arena_size = arena_size,
        };
    }

    pub fn deinit(self: *ArenaPool) void {
        for (self.arenas.items) |*arena| {
            arena.allocator.deinit();
        }
        self.arenas.deinit();
    }

    /// Acquire an arena from the pool
    pub fn acquire(self: *ArenaPool) !*std.heap.ArenaAllocator {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Look for an unused arena
        for (self.arenas.items) |*arena| {
            if (!arena.in_use) {
                arena.in_use = true;
                _ = arena.allocator.reset(.retain_capacity);
                return &arena.allocator;
            }
        }

        // Create a new arena if none available
        const arena = try self.arenas.addOne();
        arena.* = .{
            .allocator = std.heap.ArenaAllocator.init(self.parent_allocator),
            .in_use = true,
        };
        return &arena.allocator;
    }

    /// Release an arena back to the pool
    pub fn release(self: *ArenaPool, arena: *std.heap.ArenaAllocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.arenas.items) |*item| {
            if (&item.allocator == arena) {
                item.in_use = false;
                return;
            }
        }
    }
};

/// Scoped arena handle that automatically releases on deinit
pub const ScopedArena = struct {
    pool: *ArenaPool,
    arena: *std.heap.ArenaAllocator,

    pub fn init(pool: *ArenaPool) !ScopedArena {
        return .{
            .pool = pool,
            .arena = try pool.acquire(),
        };
    }

    pub fn deinit(self: ScopedArena) void {
        self.pool.release(self.arena);
    }

    pub fn allocator(self: ScopedArena) mem.Allocator {
        return self.arena.allocator();
    }
};