const std = @import("std");

pub const DiskError = error{
    FileExists,
    CreateFailed,
    SeekFailed,
    WriteFailed,
};

pub fn createRawDisk(path: [:0]const u8, size_mb: u64) !void {
    const size_bytes = size_mb * 1024 * 1024;

    if (std.fs.cwd().statFile(path)) |_| {
        return DiskError.FileExists;
    } else |_| {}

    const file = std.fs.cwd().createFileZ(path, .{}) catch return DiskError.CreateFailed;
    defer file.close();

    file.seekTo(size_bytes - 1) catch return DiskError.SeekFailed;
    var buf: [1]u8 = .{0};
    _ = file.write(&buf) catch return DiskError.WriteFailed;

    std.debug.print("Created disk image: {s} ({d} MB)\n", .{ path, size_mb });
}
