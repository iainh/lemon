const std = @import("std");

pub const ImageType = enum {
    iso,
    qcow2,
    raw,
};

pub const Image = struct {
    name: []const u8,
    description: []const u8,
    url: []const u8,
    filename: []const u8,
    image_type: ImageType,
    size_hint: []const u8,
};

pub const images = [_]Image{
    .{
        .name = "ubuntu",
        .description = "Ubuntu 24.04 LTS (Noble Numbat) cloud image",
        .url = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img",
        .filename = "ubuntu-noble-arm64.img",
        .image_type = .qcow2,
        .size_hint = "~600MB",
    },
    .{
        .name = "ubuntu-22.04",
        .description = "Ubuntu 22.04 LTS (Jammy Jellyfish) cloud image",
        .url = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img",
        .filename = "ubuntu-jammy-arm64.img",
        .image_type = .qcow2,
        .size_hint = "~600MB",
    },
    .{
        .name = "fedora",
        .description = "Fedora Cloud Base (qcow2) - latest stable",
        .url = "https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-43-1.6.aarch64.qcow2",
        .filename = "fedora-cloud-arm64.qcow2",
        .image_type = .qcow2,
        .size_hint = "~400MB",
    },
    .{
        .name = "debian",
        .description = "Debian stable (Trixie) generic cloud image",
        .url = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.qcow2",
        .filename = "debian-trixie-arm64.qcow2",
        .image_type = .qcow2,
        .size_hint = "~350MB",
    },
    .{
        .name = "debian-12",
        .description = "Debian 12 (Bookworm) generic cloud image",
        .url = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-arm64.qcow2",
        .filename = "debian-bookworm-arm64.qcow2",
        .image_type = .qcow2,
        .size_hint = "~350MB",
    },
    .{
        .name = "alpine",
        .description = "Alpine Linux virtual image (latest)",
        .url = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-virt-3.23.2-aarch64.iso",
        .filename = "alpine-virt-arm64.iso",
        .image_type = .iso,
        .size_hint = "~60MB",
    },
};

pub const ImageError = error{
    ImageNotFound,
    DownloadFailed,
    CreateDirFailed,
    FileExists,
    WriteFailed,
};

pub fn getImagesDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.InvalidPath;
    return std.fmt.allocPrint(allocator, "{s}/.local/share/lemon/images", .{home});
}

pub fn ensureImagesDir(allocator: std.mem.Allocator) ![]const u8 {
    const images_dir = try getImagesDir(allocator);
    std.fs.cwd().makePath(images_dir) catch return ImageError.CreateDirFailed;
    return images_dir;
}

pub fn findImage(name: []const u8) ?Image {
    for (images) |img| {
        if (std.mem.eql(u8, img.name, name)) {
            return img;
        }
    }
    return null;
}

pub fn getImagePath(allocator: std.mem.Allocator, image: Image) ![]const u8 {
    const images_dir = try getImagesDir(allocator);
    defer allocator.free(images_dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ images_dir, image.filename });
}

pub fn imageExists(allocator: std.mem.Allocator, image: Image) bool {
    const path = getImagePath(allocator, image) catch return false;
    defer allocator.free(path);
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn downloadImage(allocator: std.mem.Allocator, image: Image, force: bool) ![]const u8 {
    const images_dir = try ensureImagesDir(allocator);
    defer allocator.free(images_dir);

    const dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ images_dir, image.filename });

    if (!force) {
        std.fs.cwd().access(dest_path, .{}) catch |err| {
            if (err != error.FileNotFound) {
                return ImageError.DownloadFailed;
            }
        };
        if (std.fs.cwd().access(dest_path, .{})) |_| {
            return ImageError.FileExists;
        } else |_| {}
    }

    std.debug.print("Downloading {s}...\n", .{image.name});
    std.debug.print("  URL: {s}\n", .{image.url});
    std.debug.print("  Size: {s}\n", .{image.size_hint});
    std.debug.print("  Destination: {s}\n", .{dest_path});
    std.debug.print("\n", .{});

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-L", "-#", "-f", "-o", dest_path, image.url },
    });

    if (result) |res| {
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);

        if (res.term.Exited != 0) {
            std.debug.print("Download failed: {s}\n", .{res.stderr});
            allocator.free(dest_path);
            return ImageError.DownloadFailed;
        }
    } else |_| {
        allocator.free(dest_path);
        return ImageError.DownloadFailed;
    }

    std.debug.print("\nDownloaded to: {s}\n", .{dest_path});
    return dest_path;
}

pub fn printImageList() void {
    std.debug.print("Available images (aarch64/arm64):\n\n", .{});
    for (images) |img| {
        const type_str = switch (img.image_type) {
            .iso => "ISO",
            .qcow2 => "qcow2",
            .raw => "raw",
        };
        std.debug.print("  {s: <16} {s: <6} {s: <10} {s}\n", .{
            img.name,
            type_str,
            img.size_hint,
            img.description,
        });
    }
    std.debug.print(
        \\
        \\Usage:
        \\  lemon pull <name>           Download an image
        \\  lemon pull <name> --force   Re-download even if exists
        \\
        \\Images are saved to ~/.local/share/lemon/images/
        \\
        \\Example:
        \\  lemon pull ubuntu
        \\  lemon run --efi --disk ~/.local/share/lemon/images/ubuntu-noble-arm64.img --gui
        \\
    , .{});
}

test "findImage returns correct image" {
    const ubuntu = findImage("ubuntu");
    try std.testing.expect(ubuntu != null);
    try std.testing.expectEqualStrings("ubuntu", ubuntu.?.name);
}

test "findImage returns null for unknown" {
    const unknown = findImage("nonexistent");
    try std.testing.expect(unknown == null);
}
