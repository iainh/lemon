const std = @import("std");
const vz = @import("vz/vz.zig");
const cli = @import("cli.zig");
const disk = @import("disk.zig");
const sig = @import("signal.zig");
const config = @import("config.zig");
const images = @import("images.zig");
const qcow2 = @import("qcow2.zig");

const app_icon = @embedFile("app_icon");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

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
        .create => |opts| createVM(allocator, opts),
        .create_macos => |opts| createMacOSVM(allocator, opts),
        .delete => |opts| deleteVM(allocator, opts.name),
        .create_disk => |opts| {
            disk.createRawDisk(opts.path, opts.size_mb) catch |err| {
                switch (err) {
                    disk.DiskError.InvalidSize => std.debug.print("Error: Disk size must be greater than zero.\n", .{}),
                    disk.DiskError.FileExists => std.debug.print("Error: File already exists: {s}\n", .{opts.path}),
                    disk.DiskError.CreateFailed => std.debug.print("Error: Failed to create file: {s}\n", .{opts.path}),
                    disk.DiskError.SeekFailed => std.debug.print("Error: Failed to seek in file\n", .{}),
                    disk.DiskError.WriteFailed => std.debug.print("Error: Failed to write to file\n", .{}),
                }
            };
        },
        .convert => |opts| convertImage(allocator, opts),
        .pull => |opts| pullImage(allocator, opts),
        .images => images.printImageList(),
        .list => listVMs(allocator),
        .inspect => |opts| inspectVM(allocator, opts.name),
        .help => cli.printHelp(),
        .version => cli.printVersion(),
    }
}

fn convertImage(allocator: std.mem.Allocator, opts: cli.ConvertOptions) void {
    std.debug.print("Converting {s} -> {s}\n", .{ opts.input, opts.output });

    qcow2.convertToRaw(allocator, opts.input, opts.output, printProgress) catch |err| {
        switch (err) {
            qcow2.Qcow2Error.InvalidMagic => std.debug.print("Error: Not a valid qcow2 file.\n", .{}),
            qcow2.Qcow2Error.UnsupportedVersion => std.debug.print("Error: Unsupported qcow2 version (only v2/v3 supported).\n", .{}),
            qcow2.Qcow2Error.Encrypted => std.debug.print("Error: Encrypted qcow2 images are not supported.\n", .{}),
            qcow2.Qcow2Error.HasBackingFile => std.debug.print("Error: Images with backing files are not supported.\n", .{}),
            qcow2.Qcow2Error.ReadError => std.debug.print("Error: Failed to read qcow2 file.\n", .{}),
            qcow2.Qcow2Error.WriteError => std.debug.print("Error: Failed to write raw file.\n", .{}),
            qcow2.Qcow2Error.SeekError => std.debug.print("Error: Failed to seek in file.\n", .{}),
            qcow2.Qcow2Error.OutOfMemory => std.debug.print("Error: Out of memory.\n", .{}),
        }
        return;
    };

    std.debug.print("\nYou can now boot with:\n", .{});
    std.debug.print("  lemon run --efi --disk {s} --gui\n", .{opts.output});
}

fn printProgress(current: u64, total: u64) void {
    const percent = (current * 100) / total;
    std.debug.print("\rProgress: {}% ({}/{})", .{ percent, current, total });
}

fn pullImage(allocator: std.mem.Allocator, opts: cli.PullOptions) void {
    if (images.findImage(opts.name)) |image| {
        if (!opts.force and images.imageExists(allocator, image)) {
            const path = images.getImagePath(allocator, image) catch {
                std.debug.print("Error: Failed to get image path.\n", .{});
                return;
            };
            defer allocator.free(path);
            std.debug.print("Image already exists: {s}\n", .{path});
            std.debug.print("Use --force to re-download.\n", .{});
            return;
        }

        const path = images.downloadImage(allocator, image, opts.force) catch |err| {
            switch (err) {
                images.ImageError.DownloadFailed => std.debug.print("Error: Download failed.\n", .{}),
                images.ImageError.CreateDirFailed => std.debug.print("Error: Failed to create images directory.\n", .{}),
                images.ImageError.FileExists => {
                    std.debug.print("Image already exists. Use --force to re-download.\n", .{});
                },
                images.ImageError.WriteFailed => std.debug.print("Error: Failed to write file.\n", .{}),
                images.ImageError.ImageNotFound => std.debug.print("Error: Image not found.\n", .{}),
                error.OutOfMemory => std.debug.print("Error: Out of memory.\n", .{}),
                error.InvalidPath => std.debug.print("Error: Invalid path (HOME not set?).\n", .{}),
            }
            return;
        };
        defer allocator.free(path);

        std.debug.print("\nTo use this image:\n", .{});
        switch (image.image_type) {
            .iso => {
                std.debug.print("  lemon run --iso {s} --disk <disk.img> --gui\n", .{path});
            },
            .qcow2, .raw => {
                std.debug.print("  lemon run --efi --disk {s} --gui\n", .{path});
            },
        }
    } else {
        std.debug.print("Error: Unknown image '{s}'.\n", .{opts.name});
        std.debug.print("Run 'lemon images' to see available images.\n", .{});
    }
}

fn listVMs(allocator: std.mem.Allocator) void {
    var cfg = config.loadConfig(allocator) catch {
        std.debug.print("Error: Failed to load config.\n", .{});
        config.printExampleConfig();
        return;
    };
    defer cfg.deinit();
    config.printVMList(cfg.value);
    if (cfg.value.vms.len == 0) {
        config.printExampleConfig();
    }
}

fn inspectVM(allocator: std.mem.Allocator, name: [:0]const u8) void {
    var cfg = config.loadConfig(allocator) catch {
        std.debug.print("Error: Failed to load config.\n", .{});
        return;
    };
    defer cfg.deinit();
    if (config.findVM(cfg.value, name)) |vm| {
        config.printVMDetails(vm);
    } else {
        std.debug.print("Error: VM '{s}' not found.\n", .{name});
        std.debug.print("Run 'lemon list' to see configured VMs.\n", .{});
    }
}

fn createVM(allocator: std.mem.Allocator, opts: cli.CreateVMOptions) void {
    const vm_config: config.VMConfig = .{
        .name = opts.name,
        .kernel = opts.kernel,
        .initrd = opts.initrd,
        .disk = opts.disk,
        .nvram = opts.nvram,
        .efi = opts.efi,
        .cmdline = opts.cmdline,
        .cpus = opts.cpus,
        .memory_mb = opts.memory_mb,
        .rosetta = opts.rosetta,
    };

    config.addVM(allocator, vm_config) catch |err| {
        switch (err) {
            config.ConfigError.ParseError => std.debug.print("Error: VM '{s}' already exists.\n", .{opts.name}),
            else => std.debug.print("Error: Failed to save VM configuration.\n", .{}),
        }
        return;
    };

    std.debug.print("Created VM '{s}'\n", .{opts.name});
}

fn deleteVM(allocator: std.mem.Allocator, name: [:0]const u8) void {
    const removed = config.removeVM(allocator, name) catch {
        std.debug.print("Error: Failed to delete VM.\n", .{});
        return;
    };

    if (removed) {
        std.debug.print("Deleted VM '{s}'\n", .{name});
    } else {
        std.debug.print("Error: VM '{s}' not found.\n", .{name});
    }
}

fn createMacOSVM(allocator: std.mem.Allocator, opts: cli.CreateMacOSOptions) void {
    if (!vz.isSupported()) {
        std.debug.print("Error: Virtualization is not supported on this system.\n", .{});
        return;
    }

    if (!vz.isMacOSVMSupported()) {
        std.debug.print("Error: macOS VMs are only supported on Apple Silicon.\n", .{});
        return;
    }

    std.debug.print("🍋 Creating macOS VM '{s}'...\n", .{opts.name});

    const vm_dir = config.ensureVMDir(allocator, opts.name) catch {
        std.debug.print("Error: Failed to create VM directory.\n", .{});
        return;
    };
    defer allocator.free(vm_dir);

    std.debug.print("  VM directory: {s}\n", .{vm_dir});

    const restore_image = blk: {
        if (opts.ipsw) |ipsw_path| {
            std.debug.print("  Loading restore image: {s}\n", .{ipsw_path});
            break :blk vz.loadRestoreImage(ipsw_path) orelse {
                std.debug.print("Error: Failed to load restore image.\n", .{});
                return;
            };
        } else {
            std.debug.print("  Fetching latest macOS restore image...\n", .{});
            std.debug.print("  (This requires network access to Apple servers)\n", .{});
            break :blk vz.fetchLatestSupportedRestoreImage() orelse {
                std.debug.print("Error: Failed to fetch latest macOS restore image.\n", .{});
                std.debug.print("\nApple's restore image service may be temporarily unavailable.\n", .{});
                std.debug.print("You can download an IPSW manually from:\n", .{});
                std.debug.print("  https://ipsw.me/product/VirtualMac2,1\n", .{});
                std.debug.print("\nIMPORTANT: Select 'Apple Virtual Machine 1' as the device.\n", .{});
                std.debug.print("Then run:\n", .{});
                std.debug.print("  lemon create-macos {s} --ipsw /path/to/macOS.ipsw\n", .{opts.name});
                return;
            };
        }
    };
    defer restore_image.deinit();

    if (restore_image.buildVersion()) |build| {
        std.debug.print("  macOS build: {s}\n", .{build});
    }
    if (restore_image.url()) |restore_url| {
        std.debug.print("  Restore image URL: {s}\n", .{restore_url});
    }

    const requirements = restore_image.mostFeaturefulSupportedConfiguration() orelse {
        std.debug.print("Error: This macOS version is not supported on this Mac.\n", .{});
        return;
    };
    defer requirements.deinit();

    const hw_model = requirements.hardwareModel() orelse {
        std.debug.print("Error: Failed to get hardware model from requirements.\n", .{});
        return;
    };
    defer hw_model.deinit();

    if (!hw_model.isSupported()) {
        std.debug.print("Error: Hardware model is not supported on this Mac.\n", .{});
        return;
    }

    const min_cpus = requirements.minimumSupportedCPUCount();
    const min_memory = requirements.minimumSupportedMemorySize();
    const cpus = if (opts.cpus < min_cpus) @as(u32, @intCast(min_cpus)) else opts.cpus;
    const memory = if (opts.memory_mb * 1024 * 1024 < min_memory) min_memory else opts.memory_mb * 1024 * 1024;

    std.debug.print("  CPUs: {d} (min: {d})\n", .{ cpus, min_cpus });
    std.debug.print("  Memory: {d} MB (min: {d} MB)\n", .{ memory / 1024 / 1024, min_memory / 1024 / 1024 });

    const machine_id = vz.MacMachineIdentifier.init() orelse {
        std.debug.print("Error: Failed to create machine identifier.\n", .{});
        return;
    };
    defer machine_id.deinit();

    const aux_storage_path_slice = std.fmt.allocPrint(allocator, "{s}/aux_storage.bin", .{vm_dir}) catch {
        std.debug.print("Error: Out of memory.\n", .{});
        return;
    };
    defer allocator.free(aux_storage_path_slice);
    const aux_storage_path = allocator.dupeZ(u8, aux_storage_path_slice) catch {
        std.debug.print("Error: Out of memory.\n", .{});
        return;
    };
    defer allocator.free(aux_storage_path);

    const aux_storage = vz.MacAuxiliaryStorage.create(aux_storage_path, hw_model) orelse {
        std.debug.print("Error: Failed to create auxiliary storage.\n", .{});
        return;
    };
    defer aux_storage.deinit();
    std.debug.print("  Auxiliary storage: {s}\n", .{aux_storage_path});

    const disk_path_slice = std.fmt.allocPrint(allocator, "{s}/disk.img", .{vm_dir}) catch {
        std.debug.print("Error: Out of memory.\n", .{});
        return;
    };
    defer allocator.free(disk_path_slice);
    const disk_path = allocator.dupeZ(u8, disk_path_slice) catch {
        std.debug.print("Error: Out of memory.\n", .{});
        return;
    };
    defer allocator.free(disk_path);

    const disk_size_bytes = opts.disk_size_gb * 1024 * 1024 * 1024;
    disk.createRawDisk(disk_path, opts.disk_size_gb * 1024) catch |err| {
        switch (err) {
            disk.DiskError.FileExists => {},
            else => {
                std.debug.print("Error: Failed to create disk image.\n", .{});
                return;
            },
        }
    };
    std.debug.print("  Disk: {s} ({d} GB)\n", .{ disk_path, opts.disk_size_gb });
    _ = disk_size_bytes;

    const hw_model_path_slice = std.fmt.allocPrint(allocator, "{s}/hardware_model.bin", .{vm_dir}) catch {
        std.debug.print("Error: Out of memory.\n", .{});
        return;
    };
    defer allocator.free(hw_model_path_slice);
    const hw_model_path = allocator.dupeZ(u8, hw_model_path_slice) catch {
        std.debug.print("Error: Out of memory.\n", .{});
        return;
    };
    defer allocator.free(hw_model_path);

    const machine_id_path_slice = std.fmt.allocPrint(allocator, "{s}/machine_id.bin", .{vm_dir}) catch {
        std.debug.print("Error: Out of memory.\n", .{});
        return;
    };
    defer allocator.free(machine_id_path_slice);
    const machine_id_path = allocator.dupeZ(u8, machine_id_path_slice) catch {
        std.debug.print("Error: Out of memory.\n", .{});
        return;
    };
    defer allocator.free(machine_id_path);

    saveDataRepresentation(hw_model.dataRepresentation(), hw_model_path) catch {
        std.debug.print("Error: Failed to save hardware model.\n", .{});
        return;
    };

    saveDataRepresentation(machine_id.dataRepresentation(), machine_id_path) catch {
        std.debug.print("Error: Failed to save machine identifier.\n", .{});
        return;
    };

    const vm_config: config.VMConfig = .{
        .name = opts.name,
        .vm_type = .macos,
        .disk = disk_path,
        .cpus = cpus,
        .memory_mb = memory / 1024 / 1024,
        .hardware_model = hw_model_path,
        .machine_id = machine_id_path,
        .aux_storage = aux_storage_path,
        .display_width = opts.width,
        .display_height = opts.height,
    };

    config.addVM(allocator, vm_config) catch |err| {
        switch (err) {
            config.ConfigError.ParseError => std.debug.print("Error: VM '{s}' already exists.\n", .{opts.name}),
            else => std.debug.print("Error: Failed to save VM configuration.\n", .{}),
        }
        return;
    };

    std.debug.print("\n✅ macOS VM '{s}' created successfully!\n", .{opts.name});

    if (opts.no_install) {
        std.debug.print("\nSkipping installation (--no-install specified).\n", .{});
        std.debug.print("To boot the VM:\n", .{});
        std.debug.print("  lemon run {s} --gui\n", .{opts.name});
        return;
    }

    const ipsw_path = blk: {
        if (opts.ipsw) |path| {
            break :blk allocator.dupeZ(u8, path) catch {
                std.debug.print("Error: Out of memory.\n", .{});
                return;
            };
        } else {
            const restore_url = restore_image.url() orelse {
                std.debug.print("Error: Failed to get restore image URL.\n", .{});
                std.debug.print("To boot the VM:\n", .{});
                std.debug.print("  lemon run {s} --gui\n", .{opts.name});
                return;
            };

            const ipsw_dest_slice = std.fmt.allocPrint(allocator, "{s}/restore.ipsw", .{vm_dir}) catch {
                std.debug.print("Error: Out of memory.\n", .{});
                return;
            };
            defer allocator.free(ipsw_dest_slice);
            const ipsw_dest = allocator.dupeZ(u8, ipsw_dest_slice) catch {
                std.debug.print("Error: Out of memory.\n", .{});
                return;
            };

            std.debug.print("\n📥 Downloading macOS restore image...\n", .{});
            std.debug.print("  URL: {s}\n", .{restore_url});
            std.debug.print("  Destination: {s}\n", .{ipsw_dest});
            std.debug.print("  (This may take a while, ~13GB)\n", .{});

            if (!vz.downloadFile(restore_url, ipsw_dest, null)) {
                std.debug.print("Error: Failed to download restore image.\n", .{});
                std.debug.print("You can download manually from:\n", .{});
                std.debug.print("  {s}\n", .{restore_url});
                std.debug.print("Then run:\n", .{});
                std.debug.print("  lemon create-macos {s} --ipsw /path/to/restore.ipsw\n", .{opts.name});
                return;
            }

            std.debug.print("  ✅ Download complete!\n", .{});
            break :blk ipsw_dest;
        }
    };
    defer allocator.free(ipsw_path);

    std.debug.print("\n🔧 Installing macOS...\n", .{});
    std.debug.print("  (This will take 15-30 minutes)\n", .{});

    const install_platform = vz.MacPlatformConfiguration.init(hw_model, machine_id, aux_storage) orelse {
        std.debug.print("Error: Failed to create platform configuration for install.\n", .{});
        return;
    };

    const install_boot_loader = vz.MacOSBootLoader.init() orelse {
        std.debug.print("Error: Failed to create boot loader for install.\n", .{});
        return;
    };

    const install_config = vz.Configuration.init(cpus, memory) orelse {
        std.debug.print("Error: Failed to create VM configuration for install.\n", .{});
        return;
    };

    install_config.setMacPlatform(install_platform);
    install_config.setMacOSBootLoader(install_boot_loader);

    const install_storage = vz.Storage.initDiskImage(disk_path, false) orelse {
        std.debug.print("Error: Failed to attach disk for install.\n", .{});
        return;
    };
    install_config.addStorageDevice(install_storage);

    if (vz.Network.initNAT()) |net| {
        install_config.addNetworkDevice(net);
    }

    install_config.addEntropy();

    if (!install_config.validate()) {
        std.debug.print("Error: Invalid VM configuration for install.\n", .{});
        return;
    }

    const install_vm = vz.VirtualMachine.init(install_config) orelse {
        std.debug.print("Error: Failed to create VM for install.\n", .{});
        return;
    };

    var installer = vz.MacOSInstaller.init(install_vm, ipsw_path) orelse {
        std.debug.print("Error: Failed to create macOS installer.\n", .{});
        return;
    };
    defer installer.deinit();

    const install_result = installer.install(&printInstallProgress);

    switch (install_result) {
        .success => {
            std.debug.print("\n\n✅ macOS installation complete!\n", .{});
            std.debug.print("\nTo boot your new macOS VM:\n", .{});
            std.debug.print("  lemon run {s} --gui\n", .{opts.name});
        },
        .failed => {
            std.debug.print("\n\n❌ macOS installation failed.\n", .{});
            std.debug.print("The VM has been created but macOS is not installed.\n", .{});
            std.debug.print("You may need to delete and recreate the VM.\n", .{});
        },
        .pending => unreachable,
    }
}

fn printInstallProgress(progress: f64) void {
    const percent = @as(u32, @intFromFloat(progress * 100));
    std.debug.print("\r  Installing: {d}%", .{percent});
}

fn saveDataRepresentation(data: vz.objc.Object, path: [:0]const u8) !void {
    const length = data.msgSend(usize, vz.objc.sel("length"), .{});
    const bytes = data.msgSend([*]const u8, vz.objc.sel("bytes"), .{});

    const file = std.fs.cwd().createFile(path, .{}) catch return error.WriteFailed;
    defer file.close();
    file.writeAll(bytes[0..length]) catch return error.WriteFailed;
}

fn loadDataRepresentation(allocator: std.mem.Allocator, path: []const u8) ?vz.objc.Object {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    const data = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return null;
    defer allocator.free(data);

    const ns_data = vz.objc.getClass("NSData") orelse return null;
    return ns_data.msgSend(vz.objc.Object, vz.objc.sel("dataWithBytes:length:"), .{
        data.ptr,
        @as(c_ulong, data.len),
    });
}

fn runMacOSVM(allocator: std.mem.Allocator, vm: config.VMConfig, gui: bool, width_override: u32, height_override: u32) void {
    if (!vz.isMacOSVMSupported()) {
        std.debug.print("Error: macOS VMs are only supported on Apple Silicon.\n", .{});
        return;
    }

    std.debug.print("🍋 Lemon - Starting macOS VM '{s}'\n", .{vm.name});

    const hw_model_path = vm.hardware_model orelse {
        std.debug.print("Error: VM missing hardware_model path.\n", .{});
        return;
    };
    const machine_id_path = vm.machine_id orelse {
        std.debug.print("Error: VM missing machine_id path.\n", .{});
        return;
    };
    const aux_storage_path = vm.aux_storage orelse {
        std.debug.print("Error: VM missing aux_storage path.\n", .{});
        return;
    };
    const disk_path = vm.disk orelse {
        std.debug.print("Error: VM missing disk path.\n", .{});
        return;
    };

    const hw_model_data = loadDataRepresentation(allocator, hw_model_path) orelse {
        std.debug.print("Error: Failed to load hardware model from {s}\n", .{hw_model_path});
        return;
    };
    const hw_model = vz.MacHardwareModel.initFromData(hw_model_data) orelse {
        std.debug.print("Error: Failed to create hardware model.\n", .{});
        return;
    };
    defer hw_model.deinit();

    if (!hw_model.isSupported()) {
        std.debug.print("Error: Hardware model is not supported on this Mac.\n", .{});
        return;
    }

    const machine_id_data = loadDataRepresentation(allocator, machine_id_path) orelse {
        std.debug.print("Error: Failed to load machine identifier from {s}\n", .{machine_id_path});
        return;
    };
    const machine_id = vz.MacMachineIdentifier.initFromData(machine_id_data) orelse {
        std.debug.print("Error: Failed to create machine identifier.\n", .{});
        return;
    };
    defer machine_id.deinit();

    const aux_storage_path_z = allocator.dupeZ(u8, aux_storage_path) catch {
        std.debug.print("Error: Out of memory.\n", .{});
        return;
    };
    defer allocator.free(aux_storage_path_z);

    const aux_storage = vz.MacAuxiliaryStorage.load(aux_storage_path_z) orelse {
        std.debug.print("Error: Failed to load auxiliary storage from {s}\n", .{aux_storage_path});
        return;
    };
    defer aux_storage.deinit();

    const platform = vz.MacPlatformConfiguration.init(hw_model, machine_id, aux_storage) orelse {
        std.debug.print("Error: Failed to create platform configuration.\n", .{});
        return;
    };
    defer platform.deinit();

    const boot_loader = vz.MacOSBootLoader.init() orelse {
        std.debug.print("Error: Failed to create macOS boot loader.\n", .{});
        return;
    };
    defer boot_loader.deinit();

    const memory_bytes = vm.memory_mb * 1024 * 1024;
    const vz_config = vz.Configuration.init(vm.cpus, memory_bytes) orelse {
        std.debug.print("Error: Failed to create VM configuration.\n", .{});
        return;
    };
    defer vz_config.deinit();

    vz_config.setMacPlatform(platform);
    vz_config.setMacOSBootLoader(boot_loader);

    const disk_path_z = allocator.dupeZ(u8, disk_path) catch {
        std.debug.print("Error: Out of memory.\n", .{});
        return;
    };
    defer allocator.free(disk_path_z);

    const storage = vz.Storage.initDiskImage(disk_path_z, false) orelse {
        std.debug.print("Error: Failed to attach disk: {s}\n", .{disk_path});
        return;
    };
    vz_config.addStorageDevice(storage);

    if (vz.Network.initNAT()) |net| {
        vz_config.addNetworkDevice(net);
    }

    vz_config.addEntropy();

    const display_width = if (width_override != 1280) width_override else vm.display_width;
    const display_height = if (height_override != 720) height_override else vm.display_height;

    const graphics = vz.MacGraphicsDevice.init(display_width, display_height, 144) orelse {
        std.debug.print("Error: Failed to create Mac graphics device.\n", .{});
        return;
    };
    vz_config.addMacGraphicsDevice(graphics);

    vz_config.addKeyboard();
    vz_config.addPointingDevice();

    std.debug.print("  CPUs: {d}, Memory: {d} MB\n", .{ vm.cpus, vm.memory_mb });
    std.debug.print("  Disk: {s}\n", .{disk_path});
    std.debug.print("  Display: {d}x{d}\n", .{ display_width, display_height });

    if (!vz_config.validate()) {
        std.debug.print("Error: Invalid VM configuration.\n", .{});
        return;
    }

    var mac_vm = vz.VirtualMachine.init(vz_config) orelse {
        std.debug.print("Error: Failed to create virtual machine.\n", .{});
        return;
    };

    sig.installHandlers() catch {
        std.debug.print("Warning: Failed to install signal handlers.\n", .{});
    };

    std.debug.print("Starting macOS VM...\n", .{});

    if (!mac_vm.canStart()) {
        std.debug.print("Error: VM cannot start. State: {s}\n", .{@tagName(mac_vm.state())});
        return;
    }

    const start_result = mac_vm.start();
    switch (start_result) {
        .success => std.debug.print("macOS VM started successfully.\n", .{}),
        .failed => {
            std.debug.print("Error: macOS VM failed to start.\n", .{});
            return;
        },
        .pending => unreachable,
    }

    if (gui) {
        var app = vz.NSApplication.sharedApplication() orelse {
            std.debug.print("Error: Failed to get NSApplication.\n", .{});
            return;
        };
        _ = app.setActivationPolicy(0);

        if (vz.NSImage.initWithData(app_icon)) |icon| {
            app.setApplicationIconImage(icon);
        }

        const rect = vz.NSRect{
            .origin = .{ .x = 100, .y = 100 },
            .size = .{ .width = @floatFromInt(display_width), .height = @floatFromInt(display_height) },
        };

        var window = vz.NSWindow.initWithContentRect(rect, 15, 2, false) orelse {
            std.debug.print("Error: Failed to create window.\n", .{});
            return;
        };
        const title_slice = std.fmt.allocPrint(allocator, "Lemon - {s}", .{vm.name}) catch {
            window.setTitle("Lemon VM");
            return;
        };
        defer allocator.free(title_slice);
        const title = allocator.dupeZ(u8, title_slice) catch {
            window.setTitle("Lemon VM");
            return;
        };
        defer allocator.free(title);
        window.setTitle(title);

        var vm_view = vz.VirtualMachineView.init() orelse {
            std.debug.print("Error: Failed to create VM view.\n", .{});
            return;
        };
        vm_view.setVirtualMachine(mac_vm.obj);
        vm_view.setAutomaticallyReconfiguresDisplay(true);

        window.setContentView(vm_view.obj);
        window.makeKeyAndOrderFront(null);
        app.activateIgnoringOtherApps(true);

        std.debug.print("macOS VM running. Press Ctrl+C to stop.\n", .{});

        while (!sig.isShutdownRequested()) {
            const state = mac_vm.state();
            if (state == .stopped or state == .@"error") {
                std.debug.print("\nVM stopped. State: {s}\n", .{@tagName(state)});
                break;
            }
            app.runOnce();
        }

        if (sig.isShutdownRequested()) {
            std.debug.print("\nShutdown requested, stopping VM...\n", .{});
            if (mac_vm.canRequestStop()) {
                _ = mac_vm.requestStop();
                while (mac_vm.state() != .stopped and mac_vm.state() != .@"error") {
                    app.runOnce();
                }
            }
            std.debug.print("VM stopped.\n", .{});
        }
    } else {
        std.debug.print("Note: macOS VMs require --gui to display. Use 'lemon run {s} --gui'\n", .{vm.name});
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
    var nvram_path: ?[:0]const u8 = opts.nvram;
    var efi_boot: bool = opts.efi;
    var cmdline: [:0]const u8 = opts.cmdline;
    var cpus: u32 = opts.cpus;
    var memory_mb: u64 = opts.memory_mb;
    var rosetta: bool = opts.rosetta;
    const shares = opts.shares;
    const share_count = opts.share_count;
    const gui = opts.gui;
    const width = opts.width;
    const height = opts.height;

    const vsock = opts.vsock;
    const audio = opts.audio;

    if (opts.vm_name) |name| {
        var cfg = config.loadConfig(allocator) catch {
            std.debug.print("Error: Failed to load config.\n", .{});
            return;
        };
        defer cfg.deinit();
        if (config.findVM(cfg.value, name)) |vm| {
            if (vm.vm_type == .macos) {
                runMacOSVM(allocator, vm, opts.gui, opts.width, opts.height);
                return;
            }
            if (vm.kernel) |k| kernel = allocator.dupeZ(u8, k) catch null;
            if (vm.initrd) |i| initrd = allocator.dupeZ(u8, i) catch null;
            if (vm.disk) |d| disk_path = allocator.dupeZ(u8, d) catch null;
            if (vm.nvram) |n| nvram_path = allocator.dupeZ(u8, n) catch null;
            efi_boot = vm.efi;
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

    const is_efi_boot = iso_path != null or efi_boot;

    if (!is_efi_boot and kernel == null) {
        std.debug.print("Error: No kernel, --efi, or --iso specified.\n", .{});
        return;
    }

    sig.installHandlers() catch {
        std.debug.print("Warning: Failed to install signal handlers.\n", .{});
    };

    std.debug.print("🍋 Lemon - Starting VM\n", .{});
    if (is_efi_boot) {
        if (iso_path) |iso| {
            std.debug.print("  Boot mode: EFI (ISO)\n", .{});
            std.debug.print("  ISO: {s}\n", .{iso});
        } else {
            std.debug.print("  Boot mode: EFI (disk)\n", .{});
        }
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

    const vz_config = vz.Configuration.init(cpus, memory_mb * 1024 * 1024) orelse {
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

        const efi_boot_loader = vz.EFIBootLoader.init(store) orelse {
            std.debug.print("Error: Failed to create EFI boot loader.\n", .{});
            return;
        };
        std.debug.print("  EFI boot loader created\n", .{});

        const platform = vz.GenericPlatformConfiguration.init() orelse {
            std.debug.print("Error: Failed to create platform configuration.\n", .{});
            return;
        };

        vz_config.setEFIBootLoader(efi_boot_loader);
        vz_config.setPlatform(platform);

        if (iso_path) |iso| {
            const iso_storage = vz.USBStorage.initWithISO(iso) orelse {
                std.debug.print("Error: Failed to attach ISO: {s}\n", .{iso});
                return;
            };
            vz_config.addUSBStorage(iso_storage);
        }
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
        vz_config.addKeyboard();
        vz_config.addPointingDevice();
        std.debug.print("  Input: USB\n", .{});
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

        if (vz.NSImage.initWithData(app_icon)) |icon| {
            app.setApplicationIconImage(icon);
        }

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
        vm_view.setAutomaticallyReconfiguresDisplay(true);

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

test "images module" {
    _ = images;
}
