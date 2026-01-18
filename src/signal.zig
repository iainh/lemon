const std = @import("std");
const posix = std.posix;

var g_shutdown_requested = std.atomic.Value(bool).init(false);

pub fn isShutdownRequested() bool {
    return g_shutdown_requested.load(.acquire);
}

pub fn requestShutdown() void {
    g_shutdown_requested.store(true, .release);
}

fn signalHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    requestShutdown();
}

pub fn installHandlers() !void {
    const handler: posix.Sigaction.handler_fn = @ptrCast(&signalHandler);

    var action: posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = 0,
        .flags = 0,
    };

    posix.sigaction(posix.SIG.INT, &action, null);
    posix.sigaction(posix.SIG.TERM, &action, null);
}
