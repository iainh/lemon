const std = @import("std");
const vz = @import("vz/vz.zig");
const cli = @import("cli.zig");
const disk = @import("disk.zig");

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cmd = cli.parseArgs(allocator) catch |err| {
        switch (err) {
            cli.ParseError.MissingCommand => cli.printHelp(),
            cli.ParseError.UnknownCommand => {
                std.debug.print("Error: Unknown command. Use 'lemon help' for usage.\n", .{});
            },
            cli.ParseError.MissingRequiredArg => {
                std.debug.print("Error: Missing required argument.\n", .{});
                cli.printHelp();
            },
            cli.ParseError.InvalidValue => {
                std.debug.print("Error: Invalid value for argument.\n", .{});
            },
            cli.ParseError.OutOfMemory => {
                std.debug.print("Error: Out of memory.\n", .{});
            },
        }
        return;
    };

    switch (cmd) {
        .run => |opts| runVM(opts),
        .create_disk => |opts| {
            disk.createRawDisk(opts.path, opts.size_mb) catch |err| {
                switch (err) {
                    disk.DiskError.FileExists => std.debug.print("Error: File already exists: {s}\n", .{opts.path}),
                    disk.DiskError.CreateFailed => std.debug.print("Error: Failed to create file: {s}\n", .{opts.path}),
                    disk.DiskError.SeekFailed => std.debug.print("Error: Failed to seek in file\n", .{}),
                    disk.DiskError.WriteFailed => std.debug.print("Error: Failed to write to file\n", .{}),
                }
            };
        },
        .help => cli.printHelp(),
        .version => cli.printVersion(),
    }
}

fn runVM(opts: cli.RunOptions) void {
    if (!vz.isSupported()) {
        std.debug.print("Error: Virtualization is not supported on this system.\n", .{});
        return;
    }

    std.debug.print("🍋 Lemon - Starting VM\n", .{});
    std.debug.print("  Kernel: {s}\n", .{opts.kernel});
    if (opts.initrd) |initrd| {
        std.debug.print("  Initrd: {s}\n", .{initrd});
    }
    if (opts.disk) |d| {
        std.debug.print("  Disk: {s}\n", .{d});
    }
    std.debug.print("  CPUs: {d}\n", .{opts.cpus});
    std.debug.print("  Memory: {d} MB\n", .{opts.memory_mb});
    std.debug.print("  Cmdline: {s}\n", .{opts.cmdline});

    const boot_loader = vz.LinuxBootLoader.init(opts.kernel, opts.initrd, opts.cmdline) orelse {
        std.debug.print("Error: Failed to create boot loader. Check kernel path.\n", .{});
        return;
    };

    var config = vz.Configuration.init(opts.cpus, opts.memory_mb * 1024 * 1024) orelse {
        std.debug.print("Error: Failed to create VM configuration.\n", .{});
        return;
    };
    defer config.deinit();

    config.setBootLoader(boot_loader);
    config.addSerialConsole();
    config.addEntropy();

    if (opts.disk) |disk_path| {
        const storage = vz.Storage.initDiskImage(disk_path, false) orelse {
            std.debug.print("Error: Failed to attach disk: {s}\n", .{disk_path});
            return;
        };
        config.addStorageDevice(storage);
    }

    if (vz.Network.initNAT()) |net| {
        config.addNetworkDevice(net);
    } else {
        std.debug.print("Warning: Failed to create NAT network device.\n", .{});
    }

    var vm = vz.VirtualMachine.init(config) orelse {
        std.debug.print("Error: Failed to create virtual machine.\n", .{});
        return;
    };

    std.debug.print("\nVM created. Starting requires run loop integration (Phase 2).\n", .{});
    std.debug.print("Current state: {s}\n", .{@tagName(vm.state())});
}

test "cli parsing" {
    _ = cli;
}

test "disk module" {
    _ = disk;
}

test "vz module" {
    _ = vz.isSupported();
}
