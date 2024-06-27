const std = @import("std");
const sd = @import("sd_notify");

// socat unix-recv:/tmp/test.sock -
// zig build && NOTIFY_SOCKET=/tmp/test.sock zig-out/bin/examples-basic
pub fn main() !void {
    std.log.info("starting....", .{});

    const notifications = try sd.Notifications.init(.{});
    defer notifications.deinit();

    // In the vast majority of cases this line is all you need but you can get
    // fancy.
    try notifications.notify(.ready);

    try notifications.notify_n(&[_]sd.State{
        .ready,
        .{ .status = "Ready to accept connections..." },
    });
    std.posix.nanosleep(2, 0);
    try notifications.notify(.reloading);
    std.posix.nanosleep(2, 0);
    try notifications.notify(.stopping);
    std.posix.nanosleep(2, 0);

    // try notifications.notify(.{ .errno = 42 });
    // try notifications.notify(.{ .bus_error = "org.freedesktop.DBus.Error.TimedOut" });
    // try notifications.notify(.{ .exit_status = 1 });
    // try notifications.notify(.watchdog);
    // try notifications.notify(.watchdog_trigger);
    // try notifications.notify(.{ .watchdog_usec = 20000000 });
    // try notifications.notify(.{ .extend_timeout = 20000000 });
    // try notifications.notify(.{ .custom = "X_CUSTOM=foo" });

    std.log.info("exiting....", .{});
}
