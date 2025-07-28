const std = @import("std");
const tls = @import("tls");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Create arena pool with 2 initial arenas, 64KB each
    var arena_pool = try tls.ArenaPool.init(allocator, 2, 64 * 1024);
    defer arena_pool.deinit();

    // Example: Using scoped arena for handshake simulation
    {
        var scoped = try tls.ScopedArena.init(&arena_pool);
        defer scoped.deinit();

        const arena_allocator = scoped.allocator();
        
        // All allocations here use the arena
        const data1 = try arena_allocator.alloc(u8, 1024);
        const data2 = try arena_allocator.dupe(u8, "handshake data");
        
        _ = data1;
        _ = data2;
        
        // Memory automatically cleaned when scoped goes out of scope
    }

    std.debug.print("Arena allocator integrated successfully!\n", .{});
}