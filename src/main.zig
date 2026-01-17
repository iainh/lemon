const std = @import("std");
const vz = @import("vz/vz.zig");

pub fn main() void {
    std.debug.print("🍋 Lemon - macOS Virtualization.framework CLI\n", .{});
    std.debug.print("Version: 0.1.0\n", .{});

    const supported = vz.isSupported();
    if (supported) {
        std.debug.print("Virtualization: supported\n", .{});
    } else {
        std.debug.print("Virtualization: not supported\n", .{});
    }
}

test "basic test" {
    try std.testing.expect(true);
}

test "vz module" {
    _ = vz.isSupported();
}
