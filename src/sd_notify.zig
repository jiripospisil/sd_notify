const std = @import("std");
const cstd = @cImport({
    @cInclude("stdlib.h");
});

const log = std.log.scoped(.sd_notify);

// man 3 sd_notify
pub const State = union(enum) {
    ready,
    reloading,
    stopping,
    status: []const u8,
    errno: i32,
    bus_error: []const u8,
    exit_status: u8,
    main_pid: u32,
    watchdog,
    watchdog_trigger,
    watchdog_usec: u64,
    extend_timeout: u64,
    custom: []const u8,
};

pub const Options = struct {
    /// Unset the NOTIFY_SOCKET environment variable after initialization. This
    /// is to not propage the variable to child processes if any.
    ///
    /// Note that unsetting of env variables is a libc concept, the variable
    /// will still be visible if accessed directly.
    unset_env: bool = true,

    /// By default it's not an error if NOTIFY_SOCKET is missing. This makes it
    /// easier to run your application in both development and production under
    /// systemd without any changes.
    fail_without_socket: bool = false,
};

pub const Notifications = struct {
    sock: ?std.posix.socket_t,

    pub fn init(options: Options) !Notifications {
        const socket_path = getNotifySocketPath() orelse {
            if (options.fail_without_socket) {
                return error.Socket;
            }
            return .{ .sock = null };
        };

        const sock = try createSocket(socket_path);

        if (options.unset_env) {
            _ = cstd.unsetenv("NOTIFY_SOCKET");
        }

        return .{
            .sock = sock,
        };
    }

    pub fn notify(self: Notifications, state: State) !void {
        if (self.sock) |sock| {
            try sendState(sock, state);
        }
    }

    pub fn notify_n(self: Notifications, state: []const State) !void {
        if (self.sock) |sock| {
            for (state) |st| {
                try sendState(sock, st);
            }
        }
    }

    pub fn deinit(self: Notifications) void {
        if (self.sock) |sock| {
            std.posix.close(sock);
        }
    }
};

// man 3 sd_listen_fds
pub const LISTEN_FDS_START: u32 = 3;

/// Returns the received fds as a subslice. If the slice is not large enough, it
/// will return an error. The order of fds is not guaranteed by systemd - use
/// only if all of the fds are equivalent or there's only one.
///
/// All fds are automatically set FD_CLOEXEC to prevent inheriting by children.
/// Similarly, set unset_env to prevent the variable being available to
/// children.
///
/// Note that unsetting of env variables is a libc concept, the variable will
/// still be visible if accessed directly.
pub fn listenFds(unset_env: bool, fds: []std.posix.fd_t) ![]std.posix.fd_t {
    defer unsetEnv(unset_env);

    const pid = try getEnvParseInt(std.posix.pid_t, "LISTEN_PID") orelse return fds[0..0];
    if (pid != std.os.linux.getpid()) {
        return fds[0..0];
    }

    const count = try getEnvParseInt(u32, "LISTEN_FDS") orelse return fds[0..0];
    const end = try std.math.add(u32, LISTEN_FDS_START, count);

    if (end >= fds.len) {
        log.debug("out buffer too small to store all fds", .{});
        return error.InvalidValue;
    }

    for (LISTEN_FDS_START..end, 0..) |fd, i| {
        const fdd = @as(i32, @intCast(fd));
        try setCloExec(fdd);
        fds[i] = fdd;
    }

    return fds[0..count];
}

/// Returns a hash map of fdnames and fds.
///
/// All fds are automatically set FD_CLOEXEC to prevent inheriting by children.
/// Similarly, set unset_env to prevent the variable being available to
/// children.
///
/// Note that unsetting of env variables is a libc concept, the variable will
/// still be visible if accessed directly.
pub fn listenFdsMap(allocator: std.mem.Allocator, unset_env: bool) !?*std.StringHashMap(std.posix.fd_t) {
    defer unsetEnv(unset_env);

    const pid = try getEnvParseInt(std.posix.pid_t, "LISTEN_PID") orelse return null;
    if (pid != std.os.linux.getpid()) {
        return null;
    }

    const count = try getEnvParseInt(u32, "LISTEN_FDS") orelse return null;
    const end = try std.math.add(u32, LISTEN_FDS_START, count);

    const MapType = std.StringHashMap(std.posix.fd_t);
    const map = try allocator.create(MapType);
    map.* = MapType.init(allocator);

    const names = getEnv("LISTEN_FDNAMES") orelse return null;
    var iter = std.mem.tokenizeScalar(u8, names, ':');

    for (LISTEN_FDS_START..end) |fd| {
        const name = iter.next() orelse {
            log.debug("more fds than fdnames", .{});
            return error.InvalidValue;
        };

        const fdd = @as(i32, @intCast(fd));
        try setCloExec(fdd);
        try map.put(try allocator.dupe(u8, name), fdd);
    }

    return map;
}

fn unsetEnv(unset_env: bool) void {
    if (unset_env) {
        _ = cstd.unsetenv("LISTEN_PID");
        _ = cstd.unsetenv("LISTEN_FDS");
        _ = cstd.unsetenv("LISTEN_FDNAMES");
    }
}

fn getEnvParseInt(comptime T: type, env_name: []const u8) !?T {
    if (getEnv(env_name)) |en| {
        return std.fmt.parseInt(T, en, 10) catch |err| {
            log.debug("received invalid {s} value: {s}", .{ env_name, @errorName(err) });
            return error.InvalidValue;
        };
    }

    return null;
}

fn getEnv(name: []const u8) ?[:0]const u8 {
    if (cstd.getenv(name.ptr)) |sp| {
        return std.mem.span(sp);
    }

    return null;
}

fn setCloExec(fd: std.posix.fd_t) !void {
    var flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
    flags |= std.posix.FD_CLOEXEC;
    _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags);
}

fn sendState(sock: std.posix.socket_t, state: State) !void {
    var buf: [129]u8 = undefined;

    const state_str = switch (state) {
        .ready => "READY=1",

        .reloading => blk: {
            var ts: std.posix.timespec = undefined;
            std.posix.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts) catch |err| {
                log.debug("failed to get time: {s}", .{@errorName(err)});
                return error.State;
            };
            const usec = @as(u64, @bitCast(ts.tv_sec)) * std.time.us_per_s +
                @as(u64, @bitCast(ts.tv_nsec)) / std.time.ns_per_us;

            break :blk try formatString(&buf, "RELOADING=1\nMONOTONIC_USEC={d}", .{usec});
        },

        .stopping => "STOPPING=1",
        .status => |status| try formatString(&buf, "STATUS={s}", .{status}),
        .errno => |errno| try formatString(&buf, "ERRNO={d}", .{errno}),
        .bus_error => |bus_error| try formatString(&buf, "BUSERROR={s}", .{bus_error}),
        .exit_status => |exit_status| try formatString(&buf, "EXIT_STATUS={d}", .{exit_status}),
        .main_pid => |main_pid| try formatString(&buf, "MAIN_PID={d}", .{main_pid}),
        .watchdog => "WATCHDOG=1",
        .watchdog_trigger => "WATCHDOG=trigger",
        .watchdog_usec => |usec| try formatString(&buf, "WATCHDOG_USEC={d}", .{usec}),
        .extend_timeout => |usec| try formatString(&buf, "EXTEND_TIMEOUT_USEC={d}", .{usec}),
        .custom => |custom| try formatString(&buf, "{s}", .{custom}),
    };

    _ = std.posix.send(sock, state_str, 0) catch |err| {
        log.debug("failed to send data: {s}", .{@errorName(err)});
        return error.Socket;
    };
}

fn formatString(buf: []u8, comptime fmt: []const u8, args: anytype) ![]u8 {
    const written = std.fmt.bufPrint(buf, fmt, args) catch |err| {
        log.debug("failed to format state: {s}", .{@errorName(err)});
        return error.State;
    };

    return written;
}

fn getNotifySocketPath() ?[:0]const u8 {
    if (cstd.getenv("NOTIFY_SOCKET")) |sp| {
        return std.mem.span(sp);
    } else {
        log.debug("failed to read NOTIFY_SOCKET", .{});
        return null;
    }
}

fn createSocket(socket_path: [:0]const u8) !std.posix.socket_t {
    // TODO: Support more socket types

    const sock = std.posix.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        0,
    ) catch |err| {
        log.debug("failed to create socket: {s}", .{@errorName(err)});
        return error.Socket;
    };
    errdefer std.posix.close(sock);

    const address = std.net.Address.initUnix(socket_path) catch |err| {
        log.debug("failed to parse socket path: {s}", .{@errorName(err)});
        return error.Socket;
    };

    std.posix.connect(sock, &address.any, address.getOsSockLen()) catch |err| {
        log.debug("failed to connect: {s}", .{@errorName(err)});
        return error.Socket;
    };

    return sock;
}
