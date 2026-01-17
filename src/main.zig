const std = @import("std");
const vz = @import("vz/vz.zig");
const cli = @import("cli.zig");
const disk = @import("disk.zig");
const sig = @import("signal.zig");

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

    sig.installHandlers() catch {
        std.debug.print("Warning: Failed to install signal handlers.\n", .{});
    };

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

    var i: u8 = 0;
    while (i < opts.share_count) : (i += 1) {
        if (opts.shares[i]) |share| {
            if (vz.SharedDirectory.init(share.host_path, share.tag, false)) |dir_share| {
                config.addDirectoryShare(dir_share);
                std.debug.print("  Share: {s} -> {s}\n", .{ share.host_path, share.tag });
            } else {
                std.debug.print("Warning: Failed to share directory: {s}\n", .{share.host_path});
            }
        }
    }

    if (opts.rosetta) {
        if (vz.isRosettaSupported()) {
            if (vz.RosettaShare.init("rosetta")) |rosetta| {
                config.addRosettaShare(rosetta);
                std.debug.print("  Rosetta: enabled\n", .{});
            } else {
                std.debug.print("Warning: Failed to enable Rosetta.\n", .{});
            }
        } else {
            std.debug.print("Warning: Rosetta is not supported on this system.\n", .{});
        }
    }

    var vm = vz.VirtualMachine.init(config) orelse {
        std.debug.print("Error: Failed to create virtual machine.\n", .{});
        return;
    };

    std.debug.print("Starting VM...\n", .{});

    if (!vm.canStart()) {
        std.debug.print("Error: VM cannot start. State: {s}\n", .{@tagName(vm.state())});
        return;
    }

    const start_result = vm.start();
    switch (start_result) {
        .success => std.debug.print("VM started successfully.\n", .{}),
        .failed => {
            std.debug.print("Error: VM failed to start.\n", .{});
            return;
        },
        .pending => unreachable,
    }

    std.debug.print("VM running. Press Ctrl+C to stop.\n", .{});

    var run_loop = vz.RunLoop.current() orelse {
        std.debug.print("Error: Failed to get run loop.\n", .{});
        return;
    };

    while (!sig.isShutdownRequested()) {
        const state = vm.state();
        if (state == .stopped or state == .@"error") {
            std.debug.print("\nVM stopped. State: {s}\n", .{@tagName(state)});
            break;
        }
        run_loop.runOnce();
    }

    if (sig.isShutdownRequested()) {
        std.debug.print("\nShutdown requested, stopping VM...\n", .{});
        if (vm.canRequestStop()) {
            _ = vm.requestStop();
            while (vm.state() != .stopped and vm.state() != .@"error") {
                run_loop.runOnce();
            }
        }
        std.debug.print("VM stopped.\n", .{});
    }
}

test "cli parsing" {
    _ = cli;
}

test "disk module" {
    _ = disk;
}

test "signal module" {
    _ = sig;
}

test "vz module" {
    _ = vz.isSupported();
}
