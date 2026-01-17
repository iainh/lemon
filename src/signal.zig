const std = @import("std");
const posix = std.posix;

var g_shutdown_requested: bool = false;

pub fn isShutdownRequested() bool {
    return @atomicLoad(bool, &g_shutdown_requested, .acquire);
}

pub fn requestShutdown() void {
    @atomicStore(bool, &g_shutdown_requested, true, .release);
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
