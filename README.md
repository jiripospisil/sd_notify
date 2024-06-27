# sd\_notify

sd\_notify is a library which implements a subset of APIs for interacting with
systemd services of type "notify".

```zig
const notifications = try sd.Notifications.init(.{});
defer notifications.deinit();

try notifications.notify(.ready);

if (try sd.listenFdsMap(allocator, true)) |map| {
    var iter = map.iterator();
    while (iter.next()) |entry| {
        std.log.info("fdname {s} fd {any}", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
}
```

License MIT.
