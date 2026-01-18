const std = @import("std");

pub const Command = union(enum) {
    run: RunOptions,
    create: CreateVMOptions,
    delete: DeleteVMOptions,
    create_disk: CreateDiskOptions,
    pull: PullOptions,
    list,
    images,
    inspect: InspectOptions,
    help,
    version,
};

pub const PullOptions = struct {
    name: [:0]const u8,
    force: bool = false,
};

pub const InspectOptions = struct {
    name: [:0]const u8,
};

pub const CreateVMOptions = struct {
    name: [:0]const u8,
    kernel: ?[:0]const u8 = null,
    initrd: ?[:0]const u8 = null,
    disk: ?[:0]const u8 = null,
    nvram: ?[:0]const u8 = null,
    efi: bool = false,
    cmdline: [:0]const u8 = "console=hvc0",
    cpus: u32 = 2,
    memory_mb: u64 = 512,
    rosetta: bool = false,
};

pub const DeleteVMOptions = struct {
    name: [:0]const u8,
};

pub const ShareMount = struct {
    host_path: [:0]const u8,
    tag: [:0]const u8,
};

pub const RunOptions = struct {
    kernel: ?[:0]const u8 = null,
    initrd: ?[:0]const u8 = null,
    disk: ?[:0]const u8 = null,
    iso: ?[:0]const u8 = null,
    nvram: ?[:0]const u8 = null,
    efi: bool = false,
    cmdline: [:0]const u8 = "console=hvc0",
    cpus: u32 = 2,
    memory_mb: u64 = 512,
    shares: [8]?ShareMount = [_]?ShareMount{null} ** 8,
    share_count: u8 = 0,
    rosetta: bool = false,
    vm_name: ?[:0]const u8 = null,
    gui: bool = false,
    width: u32 = 1280,
    height: u32 = 720,
    vsock: bool = false,
    audio: bool = false,
};

pub const CreateDiskOptions = struct {
    path: [:0]const u8,
    size_mb: u64,
};

pub const ParseError = error{
    MissingCommand,
    UnknownCommand,
    MissingRequiredArg,
    InvalidValue,
    OutOfMemory,
};

pub fn parseArgs(allocator: std.mem.Allocator) ParseError!Command {
    var args = std.process.args();
    _ = args.skip(); // skip program name

    const cmd_str = args.next() orelse return ParseError.MissingCommand;

    if (std.mem.eql(u8, cmd_str, "run")) {
        return parseRunCommand(allocator, &args);
    } else if (std.mem.eql(u8, cmd_str, "create")) {
        return parseCreateVMCommand(&args);
    } else if (std.mem.eql(u8, cmd_str, "delete") or std.mem.eql(u8, cmd_str, "rm")) {
        return parseDeleteVMCommand(&args);
    } else if (std.mem.eql(u8, cmd_str, "create-disk")) {
        return parseCreateDiskCommand(&args);
    } else if (std.mem.eql(u8, cmd_str, "list") or std.mem.eql(u8, cmd_str, "ls")) {
        return .list;
    } else if (std.mem.eql(u8, cmd_str, "pull")) {
        return parsePullCommand(&args);
    } else if (std.mem.eql(u8, cmd_str, "images")) {
        return .images;
    } else if (std.mem.eql(u8, cmd_str, "inspect")) {
        return parseInspectCommand(&args);
    } else if (std.mem.eql(u8, cmd_str, "help") or std.mem.eql(u8, cmd_str, "--help") or std.mem.eql(u8, cmd_str, "-h")) {
        return .help;
    } else if (std.mem.eql(u8, cmd_str, "version") or std.mem.eql(u8, cmd_str, "--version") or std.mem.eql(u8, cmd_str, "-V")) {
        return .version;
    }

    return ParseError.UnknownCommand;
}

fn parseRunCommand(allocator: std.mem.Allocator, args: *std.process.ArgIterator) ParseError!Command {
    var opts = RunOptions{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--kernel") or std.mem.eql(u8, arg, "-k")) {
            opts.kernel = args.next() orelse return ParseError.MissingRequiredArg;
        } else if (std.mem.eql(u8, arg, "--initrd") or std.mem.eql(u8, arg, "-i")) {
            opts.initrd = args.next() orelse return ParseError.MissingRequiredArg;
        } else if (std.mem.eql(u8, arg, "--disk") or std.mem.eql(u8, arg, "-d")) {
            opts.disk = args.next() orelse return ParseError.MissingRequiredArg;
        } else if (std.mem.eql(u8, arg, "--iso")) {
            opts.iso = args.next() orelse return ParseError.MissingRequiredArg;
        } else if (std.mem.eql(u8, arg, "--nvram")) {
            opts.nvram = args.next() orelse return ParseError.MissingRequiredArg;
        } else if (std.mem.eql(u8, arg, "--efi")) {
            opts.efi = true;
        } else if (std.mem.eql(u8, arg, "--cmdline") or std.mem.eql(u8, arg, "-c")) {
            opts.cmdline = args.next() orelse return ParseError.MissingRequiredArg;
        } else if (std.mem.eql(u8, arg, "--cpus")) {
            const val = args.next() orelse return ParseError.MissingRequiredArg;
            opts.cpus = std.fmt.parseInt(u32, val, 10) catch return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--memory") or std.mem.eql(u8, arg, "-m")) {
            const val = args.next() orelse return ParseError.MissingRequiredArg;
            opts.memory_mb = std.fmt.parseInt(u64, val, 10) catch return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--share") or std.mem.eql(u8, arg, "-s")) {
            const share_arg = args.next() orelse return ParseError.MissingRequiredArg;
            if (opts.share_count >= 8) return ParseError.InvalidValue;
            if (std.mem.indexOf(u8, share_arg, ":")) |colon_idx| {
                const host_path = allocator.dupeZ(u8, share_arg[0..colon_idx]) catch return ParseError.OutOfMemory;
                const tag = allocator.dupeZ(u8, share_arg[colon_idx + 1 ..]) catch return ParseError.OutOfMemory;
                opts.shares[opts.share_count] = .{ .host_path = host_path, .tag = tag };
                opts.share_count += 1;
            } else {
                return ParseError.InvalidValue;
            }
        } else if (std.mem.eql(u8, arg, "--rosetta")) {
            opts.rosetta = true;
        } else if (std.mem.eql(u8, arg, "--gui")) {
            opts.gui = true;
        } else if (std.mem.eql(u8, arg, "--width")) {
            const val = args.next() orelse return ParseError.MissingRequiredArg;
            opts.width = std.fmt.parseInt(u32, val, 10) catch return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--height")) {
            const val = args.next() orelse return ParseError.MissingRequiredArg;
            opts.height = std.fmt.parseInt(u32, val, 10) catch return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--vsock")) {
            opts.vsock = true;
        } else if (std.mem.eql(u8, arg, "--audio")) {
            opts.audio = true;
        } else if (!std.mem.startsWith(u8, arg, "-") and opts.vm_name == null and opts.kernel == null) {
            opts.vm_name = allocator.dupeZ(u8, arg) catch return ParseError.OutOfMemory;
        }
    }

    if (opts.kernel == null and opts.iso == null and !opts.efi and opts.vm_name == null) return ParseError.MissingRequiredArg;

    return Command{ .run = opts };
}

fn parseCreateDiskCommand(args: *std.process.ArgIterator) ParseError!Command {
    const path = args.next() orelse return ParseError.MissingRequiredArg;
    const size_str = args.next() orelse return ParseError.MissingRequiredArg;
    const size_mb = std.fmt.parseInt(u64, size_str, 10) catch return ParseError.InvalidValue;

    return Command{ .create_disk = .{
        .path = path,
        .size_mb = size_mb,
    } };
}

fn parseInspectCommand(args: *std.process.ArgIterator) ParseError!Command {
    const name = args.next() orelse return ParseError.MissingRequiredArg;
    return Command{ .inspect = .{ .name = name } };
}

fn parseCreateVMCommand(args: *std.process.ArgIterator) ParseError!Command {
    var opts: CreateVMOptions = undefined;
    var has_name = false;
    var has_kernel = false;
    opts.kernel = null;
    opts.initrd = null;
    opts.disk = null;
    opts.nvram = null;
    opts.efi = false;
    opts.cmdline = "console=hvc0";
    opts.cpus = 2;
    opts.memory_mb = 512;
    opts.rosetta = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--kernel") or std.mem.eql(u8, arg, "-k")) {
            opts.kernel = args.next() orelse return ParseError.MissingRequiredArg;
            has_kernel = true;
        } else if (std.mem.eql(u8, arg, "--initrd") or std.mem.eql(u8, arg, "-i")) {
            opts.initrd = args.next() orelse return ParseError.MissingRequiredArg;
        } else if (std.mem.eql(u8, arg, "--disk") or std.mem.eql(u8, arg, "-d")) {
            opts.disk = args.next() orelse return ParseError.MissingRequiredArg;
        } else if (std.mem.eql(u8, arg, "--nvram")) {
            opts.nvram = args.next() orelse return ParseError.MissingRequiredArg;
        } else if (std.mem.eql(u8, arg, "--efi")) {
            opts.efi = true;
        } else if (std.mem.eql(u8, arg, "--cmdline") or std.mem.eql(u8, arg, "-c")) {
            opts.cmdline = args.next() orelse return ParseError.MissingRequiredArg;
        } else if (std.mem.eql(u8, arg, "--cpus")) {
            const val = args.next() orelse return ParseError.MissingRequiredArg;
            opts.cpus = std.fmt.parseInt(u32, val, 10) catch return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--memory") or std.mem.eql(u8, arg, "-m")) {
            const val = args.next() orelse return ParseError.MissingRequiredArg;
            opts.memory_mb = std.fmt.parseInt(u64, val, 10) catch return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--rosetta")) {
            opts.rosetta = true;
        } else if (!std.mem.startsWith(u8, arg, "-") and !has_name) {
            opts.name = arg;
            has_name = true;
        }
    }

    if (!has_name) return ParseError.MissingRequiredArg;
    if (!has_kernel and !opts.efi) return ParseError.MissingRequiredArg;

    return Command{ .create = opts };
}

fn parseDeleteVMCommand(args: *std.process.ArgIterator) ParseError!Command {
    const name = args.next() orelse return ParseError.MissingRequiredArg;
    return Command{ .delete = .{ .name = name } };
}

fn parsePullCommand(args: *std.process.ArgIterator) ParseError!Command {
    var opts = PullOptions{ .name = undefined, .force = false };
    var has_name = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            opts.force = true;
        } else if (!std.mem.startsWith(u8, arg, "-") and !has_name) {
            opts.name = arg;
            has_name = true;
        }
    }

    if (!has_name) return ParseError.MissingRequiredArg;
    return Command{ .pull = opts };
}

pub fn printHelp() void {
    const help =
        \\🍋 Lemon - macOS Virtualization.framework CLI
        \\
        \\USAGE:
        \\    lemon <COMMAND> [OPTIONS]
        \\
        \\COMMANDS:
        \\    run [NAME]      Boot a VM (by config name or with options)
        \\    create <NAME>   Create a new VM configuration
        \\    delete <NAME>   Delete a VM configuration (alias: rm)
        \\    list, ls        List configured VMs
        \\    inspect <NAME>  Show VM configuration details
        \\    create-disk     Create a raw disk image
        \\    pull <NAME>     Download a cloud image (run 'lemon images' for list)
        \\    images          List available images to download
        \\    help            Show this help message
        \\    version         Show version information
        \\
        \\RUN OPTIONS:
        \\    -k, --kernel <PATH>     Path to Linux kernel (for direct boot)
        \\    -i, --initrd <PATH>     Path to initial ramdisk
        \\    -d, --disk <PATH>       Path to disk image
        \\        --iso <PATH>        Boot from ISO image (uses EFI boot)
        \\        --efi               Use EFI boot (for installed disks)
        \\        --nvram <PATH>      Path to NVRAM file for EFI (default: nvram.bin)
        \\    -c, --cmdline <ARGS>    Kernel command line (default: console=hvc0)
        \\        --cpus <N>          Number of CPUs (default: 2)
        \\    -m, --memory <MB>       Memory in MB (default: 512)
        \\    -s, --share <PATH:TAG>  Share host directory (mount with: mount -t virtiofs TAG /mnt)
        \\        --rosetta           Enable Rosetta x86_64 emulation (Apple Silicon only)
        \\        --gui               Show graphical display window
        \\        --width <N>         Display width in pixels (default: 1280)
        \\        --height <N>        Display height in pixels (default: 720)
        \\        --vsock             Enable virtio socket for host-guest communication
        \\        --audio             Enable virtio sound device
        \\
        \\CREATE OPTIONS:
        \\    -k, --kernel <PATH>     Path to Linux kernel (required unless --efi)
        \\    -i, --initrd <PATH>     Path to initial ramdisk
        \\    -d, --disk <PATH>       Path to disk image
        \\        --efi               Use EFI boot mode (for installed OS)
        \\        --nvram <PATH>      Path to NVRAM file for EFI
        \\    -c, --cmdline <ARGS>    Kernel command line (default: console=hvc0)
        \\        --cpus <N>          Number of CPUs (default: 2)
        \\    -m, --memory <MB>       Memory in MB (default: 512)
        \\        --rosetta           Enable Rosetta x86_64 emulation
        \\
        \\CREATE-DISK:
        \\    lemon create-disk <PATH> <SIZE_MB>
        \\
        \\CONFIG FILE:
        \\    VMs are stored in ~/.config/lemon/vms.json
        \\
        \\EXAMPLES:
        \\    # Linux direct boot
        \\    lemon create alpine -k vmlinuz -i initrd.img -d disk.img -m 1024
        \\    lemon run alpine
        \\
        \\    # Install from ISO, then boot installed disk
        \\    lemon run --iso fedora.iso --disk disk.img --nvram fedora.nvram --gui
        \\    lemon create fedora --efi --disk disk.img --nvram fedora.nvram -m 4096
        \\    lemon run fedora --gui
        \\
        \\    # Other examples
        \\    lemon run -k vmlinuz -d disk.img -m 1024 --cpus 4
        \\    lemon run -k vmlinuz --share /Users/me/code:code --rosetta
        \\    lemon create-disk disk.img 8192
        \\
    ;
    std.debug.print("{s}", .{help});
}

pub fn printVersion() void {
    std.debug.print("lemon 0.1.0\n", .{});
}
