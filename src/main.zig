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

    var kernel: ?[:0]const u8 = opts.kernel;
    var initrd: ?[:0]const u8 = opts.initrd;
    var disk_path: ?[:0]const u8 = opts.disk;
    const iso_path: ?[:0]const u8 = opts.iso;
    const nvram_path: ?[:0]const u8 = opts.nvram;
    var cmdline: [:0]const u8 = opts.cmdline;
    var cpus: u32 = opts.cpus;
    var memory_mb: u64 = opts.memory_mb;
    var rosetta: bool = opts.rosetta;
    const shares = opts.shares;
    const share_count = opts.share_count;
    const gui = opts.gui;
    const width = opts.width;
    const height = opts.height;
    const usb_input = opts.usb_input;
    const vsock = opts.vsock;
    const audio = opts.audio;

    if (opts.vm_name) |name| {
        const cfg = config.loadConfig(allocator) catch {
            std.debug.print("Error: Failed to load config.\n", .{});
            return;
        };
        if (config.findVM(cfg, name)) |vm| {
            kernel = allocator.dupeZ(u8, vm.kernel) catch null;
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
    }

    const is_efi_boot = iso_path != null;

    if (!is_efi_boot and kernel == null) {
        std.debug.print("Error: No kernel or ISO specified.\n", .{});
        return;
    }

    sig.installHandlers() catch {
        std.debug.print("Warning: Failed to install signal handlers.\n", .{});
    };

    std.debug.print("🍋 Lemon - Starting VM\n", .{});
    if (is_efi_boot) {
        std.debug.print("  Boot mode: EFI (ISO)\n", .{});
        std.debug.print("  ISO: {s}\n", .{iso_path.?});
        if (nvram_path) |n| {
            std.debug.print("  NVRAM: {s}\n", .{n});
        }
    } else {
        std.debug.print("  Boot mode: Linux direct\n", .{});
        std.debug.print("  Kernel: {s}\n", .{kernel.?});
        if (initrd) |i| {
            std.debug.print("  Initrd: {s}\n", .{i});
        }
        std.debug.print("  Cmdline: {s}\n", .{cmdline});
    }
    if (disk_path) |d| {
        std.debug.print("  Disk: {s}\n", .{d});
    }
    std.debug.print("  CPUs: {d}\n", .{cpus});
    std.debug.print("  Memory: {d} MB\n", .{memory_mb});

    var vz_config = vz.Configuration.init(cpus, memory_mb * 1024 * 1024) orelse {
        std.debug.print("Error: Failed to create VM configuration.\n", .{});
        return;
    };
    defer vz_config.deinit();

    if (is_efi_boot) {
        const nvram_rel = nvram_path orelse "nvram.bin";

        const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch {
            std.debug.print("Error: Failed to get current directory.\n", .{});
            return;
        };
        defer allocator.free(cwd);

        const actual_nvram_path = std.fs.path.joinZ(allocator, &.{ cwd, nvram_rel }) catch {
            std.debug.print("Error: Failed to construct NVRAM path.\n", .{});
            return;
        };
        defer allocator.free(actual_nvram_path);

        const nvram_exists = blk: {
            std.fs.cwd().access(nvram_rel, .{}) catch break :blk false;
            break :blk true;
        };

        const efi_store = if (nvram_exists)
            vz.EFIVariableStore.load(actual_nvram_path)
        else
            vz.EFIVariableStore.create(actual_nvram_path);

        const store = efi_store orelse {
            std.debug.print("Error: Failed to create/load EFI variable store at: {s}\n", .{actual_nvram_path});
            return;
        };

        if (!nvram_exists) {
            std.debug.print("  Created NVRAM: {s}\n", .{actual_nvram_path});
        } else {
            std.debug.print("  Loaded NVRAM: {s}\n", .{actual_nvram_path});
        }

        const efi_boot = vz.EFIBootLoader.init(store) orelse {
            std.debug.print("Error: Failed to create EFI boot loader.\n", .{});
            return;
        };
        std.debug.print("  EFI boot loader created\n", .{});

        const platform = vz.GenericPlatformConfiguration.init() orelse {
            std.debug.print("Error: Failed to create platform configuration.\n", .{});
            return;
        };

        vz_config.setEFIBootLoader(efi_boot);
        vz_config.setPlatform(platform);

        const iso_storage = vz.USBStorage.initWithISO(iso_path.?) orelse {
            std.debug.print("Error: Failed to attach ISO: {s}\n", .{iso_path.?});
            return;
        };
        vz_config.addUSBStorage(iso_storage);
    } else {
        const boot_loader = vz.LinuxBootLoader.init(kernel.?, initrd, cmdline) orelse {
            std.debug.print("Error: Failed to create boot loader. Check kernel path.\n", .{});
            return;
        };
        vz_config.setBootLoader(boot_loader);
    }

    vz_config.addSerialConsole();
    vz_config.addEntropy();
    vz_config.addMemoryBalloon();

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

    if (vsock) {
        if (vz.VirtioSocket.init()) |socket| {
            vz_config.addSocketDevice(socket);
            std.debug.print("  Vsock: enabled (guest CID: 3)\n", .{});
        } else {
            std.debug.print("Warning: Failed to create vsock device.\n", .{});
        }
    }

    if (audio) {
        if (vz.VirtioSound.init()) |sound| {
            vz_config.addAudioDevice(sound);
            std.debug.print("  Audio: enabled\n", .{});
        } else {
            std.debug.print("Warning: Failed to create audio device.\n", .{});
        }
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

    if (gui) {
        const graphics = vz.VirtioGraphicsDevice.init(width, height) orelse {
            std.debug.print("Error: Failed to create graphics device.\n", .{});
            return;
        };
        vz_config.addGraphicsDevice(graphics);
        if (usb_input) {
            vz_config.addKeyboard();
            vz_config.addPointingDevice();
            std.debug.print("  Input: USB\n", .{});
        } else {
            vz_config.addVirtioKeyboard();
            vz_config.addVirtioPointingDevice();
        }
        std.debug.print("  Graphics: {d}x{d}\n", .{ width, height });
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

    if (gui) {
        var app = vz.NSApplication.sharedApplication() orelse {
            std.debug.print("Error: Failed to get NSApplication.\n", .{});
            return;
        };
        _ = app.setActivationPolicy(0);

        const rect = vz.NSRect{
            .origin = .{ .x = 100, .y = 100 },
            .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
        };

        var window = vz.NSWindow.initWithContentRect(rect, 15, 2, false) orelse {
            std.debug.print("Error: Failed to create window.\n", .{});
            return;
        };
        window.setTitle("Lemon VM");

        var vm_view = vz.VirtualMachineView.init() orelse {
            std.debug.print("Error: Failed to create VM view.\n", .{});
            return;
        };
        vm_view.setVirtualMachine(vm.obj);

        window.setContentView(vm_view.obj);
        window.makeKeyAndOrderFront(null);
        app.activateIgnoringOtherApps(true);

        while (!sig.isShutdownRequested()) {
            const state = vm.state();
            if (state == .stopped or state == .@"error") {
                std.debug.print("\nVM stopped. State: {s}\n", .{@tagName(state)});
                break;
            }
            app.runOnce();
        }

        if (sig.isShutdownRequested()) {
            std.debug.print("\nShutdown requested, stopping VM...\n", .{});
            if (vm.canRequestStop()) {
                _ = vm.requestStop();
                while (vm.state() != .stopped and vm.state() != .@"error") {
                    app.runOnce();
                }
            }
            std.debug.print("VM stopped.\n", .{});
        }
    } else {
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
