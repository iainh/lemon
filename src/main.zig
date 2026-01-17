const std = @import("std");
const vz = @import("vz/vz.zig");
const cli = @import("cli.zig");
const disk = @import("disk.zig");
const sig = @import("signal.zig");
const config = @import("config.zig");

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
        .run => |opts| runVM(allocator, opts),
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
        .list => listVMs(allocator),
        .inspect => |opts| inspectVM(allocator, opts.name),
        .help => cli.printHelp(),
        .version => cli.printVersion(),
    }
}

fn listVMs(allocator: std.mem.Allocator) void {
    const cfg = config.loadConfig(allocator) catch {
        std.debug.print("Error: Failed to load config.\n", .{});
        config.printExampleConfig();
        return;
    };
    config.printVMList(cfg);
    if (cfg.vms.len == 0) {
        config.printExampleConfig();
    }
}

fn inspectVM(allocator: std.mem.Allocator, name: [:0]const u8) void {
    const cfg = config.loadConfig(allocator) catch {
        std.debug.print("Error: Failed to load config.\n", .{});
        return;
    };
    if (config.findVM(cfg, name)) |vm| {
        config.printVMDetails(vm);
    } else {
        std.debug.print("Error: VM '{s}' not found.\n", .{name});
        std.debug.print("Run 'lemon list' to see configured VMs.\n", .{});
    }
}

fn runVM(allocator: std.mem.Allocator, opts: cli.RunOptions) void {
    if (!vz.isSupported()) {
        std.debug.print("Error: Virtualization is not supported on this system.\n", .{});
        return;
    }

    var kernel: [:0]const u8 = undefined;
    var initrd: ?[:0]const u8 = opts.initrd;
    var disk_path: ?[:0]const u8 = opts.disk;
    var cmdline: [:0]const u8 = opts.cmdline;
    var cpus: u32 = opts.cpus;
    var memory_mb: u64 = opts.memory_mb;
    var rosetta: bool = opts.rosetta;
    const shares = opts.shares;
    const share_count = opts.share_count;

    if (opts.vm_name) |name| {
        const cfg = config.loadConfig(allocator) catch {
            std.debug.print("Error: Failed to load config.\n", .{});
            return;
        };
        if (config.findVM(cfg, name)) |vm| {
            kernel = allocator.dupeZ(u8, vm.kernel) catch {
                std.debug.print("Error: Out of memory.\n", .{});
                return;
            };
            if (vm.initrd) |i| initrd = allocator.dupeZ(u8, i) catch null;
            if (vm.disk) |d| disk_path = allocator.dupeZ(u8, d) catch null;
            cmdline = allocator.dupeZ(u8, vm.cmdline) catch cmdline;
            cpus = vm.cpus;
            memory_mb = vm.memory_mb;
            rosetta = vm.rosetta;
        } else {
            std.debug.print("Error: VM '{s}' not found.\n", .{name});
            std.debug.print("Run 'lemon list' to see configured VMs.\n", .{});
            return;
        }
    } else if (opts.kernel) |k| {
        kernel = k;
    } else {
        std.debug.print("Error: No kernel specified.\n", .{});
        return;
    }

    sig.installHandlers() catch {
        std.debug.print("Warning: Failed to install signal handlers.\n", .{});
    };

    std.debug.print("🍋 Lemon - Starting VM\n", .{});
    std.debug.print("  Kernel: {s}\n", .{kernel});
    if (initrd) |i| {
        std.debug.print("  Initrd: {s}\n", .{i});
    }
    if (disk_path) |d| {
        std.debug.print("  Disk: {s}\n", .{d});
    }
    std.debug.print("  CPUs: {d}\n", .{cpus});
    std.debug.print("  Memory: {d} MB\n", .{memory_mb});
    std.debug.print("  Cmdline: {s}\n", .{cmdline});

    const boot_loader = vz.LinuxBootLoader.init(kernel, initrd, cmdline) orelse {
        std.debug.print("Error: Failed to create boot loader. Check kernel path.\n", .{});
        return;
    };

    var vz_config = vz.Configuration.init(cpus, memory_mb * 1024 * 1024) orelse {
        std.debug.print("Error: Failed to create VM configuration.\n", .{});
        return;
    };
    defer vz_config.deinit();

    vz_config.setBootLoader(boot_loader);
    vz_config.addSerialConsole();
    vz_config.addEntropy();

    if (disk_path) |dp| {
        const storage = vz.Storage.initDiskImage(dp, false) orelse {
            std.debug.print("Error: Failed to attach disk: {s}\n", .{dp});
            return;
        };
        vz_config.addStorageDevice(storage);
    }

    if (vz.Network.initNAT()) |net| {
        vz_config.addNetworkDevice(net);
    } else {
        std.debug.print("Warning: Failed to create NAT network device.\n", .{});
    }

    var i: u8 = 0;
    while (i < share_count) : (i += 1) {
        if (shares[i]) |share| {
            if (vz.SharedDirectory.init(share.host_path, share.tag, false)) |dir_share| {
                vz_config.addDirectoryShare(dir_share);
                std.debug.print("  Share: {s} -> {s}\n", .{ share.host_path, share.tag });
            } else {
                std.debug.print("Warning: Failed to share directory: {s}\n", .{share.host_path});
            }
        }
    }

    if (rosetta) {
        if (vz.isRosettaSupported()) {
            if (vz.RosettaShare.init("rosetta")) |rosetta_share| {
                vz_config.addRosettaShare(rosetta_share);
                std.debug.print("  Rosetta: enabled\n", .{});
            } else {
                std.debug.print("Warning: Failed to enable Rosetta.\n", .{});
            }
        } else {
            std.debug.print("Warning: Rosetta is not supported on this system.\n", .{});
        }
    }

    if (!vz_config.validate()) {
        std.debug.print("Error: Invalid VM configuration.\n", .{});
        return;
    }

    var vm = vz.VirtualMachine.init(vz_config) orelse {
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

test "config module" {
    _ = config;
}

test "vz module" {
    _ = vz.isSupported();
}
