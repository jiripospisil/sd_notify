const std = @import("std");
const sd = @import("sd_notify");

pub fn main() !void {
    std.log.info("starting....", .{});

    // Get the fds in arbitrary order.
    var out: [10]std.posix.fd_t = undefined;
    const fds = try sd.listenFds(false, &out);
    std.log.info("fds {d}", .{fds});

    // Get the fds in a map with names
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    if (try sd.listenFdsMap(arena.allocator(), true)) |map| {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            std.log.info("fdname {s} fd {any}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    std.log.info("exiting....", .{});
}
