const std = @import("std");
const vz = @import("vz/vz.zig");

pub const Command = union(enum) {
    run: RunOptions,
    create_disk: CreateDiskOptions,
    list,
    inspect: InspectOptions,
    help,
    version,
};

pub const InspectOptions = struct {
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
    virtio_input: bool = false,
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
    } else if (std.mem.eql(u8, cmd_str, "create-disk")) {
        return parseCreateDiskCommand(&args);
    } else if (std.mem.eql(u8, cmd_str, "list") or std.mem.eql(u8, cmd_str, "ls")) {
        return .list;
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
        } else if (std.mem.eql(u8, arg, "--virtio-input")) {
            opts.virtio_input = true;
        } else if (!std.mem.startsWith(u8, arg, "-") and opts.vm_name == null and opts.kernel == null) {
            opts.vm_name = allocator.dupeZ(u8, arg) catch return ParseError.OutOfMemory;
        }
    }

    if (opts.kernel == null and opts.iso == null and opts.vm_name == null) return ParseError.MissingRequiredArg;

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

pub fn printHelp() void {
    const help =
        \\🍋 Lemon - macOS Virtualization.framework CLI
        \\
        \\USAGE:
        \\    lemon <COMMAND> [OPTIONS]
        \\
        \\COMMANDS:
        \\    run [NAME]      Boot a VM (by config name or with options)
        \\    list, ls        List configured VMs
        \\    inspect <NAME>  Show VM configuration details
        \\    create-disk     Create a raw disk image
        \\    help            Show this help message
        \\    version         Show version information
        \\
        \\RUN OPTIONS:
        \\    -k, --kernel <PATH>     Path to Linux kernel (required if no NAME or ISO)
        \\    -i, --initrd <PATH>     Path to initial ramdisk
        \\    -d, --disk <PATH>       Path to disk image
        \\        --iso <PATH>        Boot from ISO image (uses EFI boot)
        \\        --nvram <PATH>      Path to NVRAM file for EFI (auto-created if missing)
        \\    -c, --cmdline <ARGS>    Kernel command line (default: console=hvc0)
        \\        --cpus <N>          Number of CPUs (default: 2)
        \\    -m, --memory <MB>       Memory in MB (default: 512)
        \\    -s, --share <PATH:TAG>  Share host directory (mount with: mount -t virtiofs TAG /mnt)
        \\        --rosetta           Enable Rosetta x86_64 emulation (Apple Silicon only)
        \\        --gui               Show graphical display window
        \\        --width <N>         Display width in pixels (default: 1280)
        \\        --height <N>        Display height in pixels (default: 720)
        \\        --virtio-input      Use virtio keyboard/mouse (lower latency for Linux)
        \\
        \\CREATE-DISK:
        \\    lemon create-disk <PATH> <SIZE_MB>
        \\
        \\CONFIG FILE:
        \\    VMs can be defined in ~/.config/lemon/vms.json
        \\    Run 'lemon list' for an example config format.
        \\
        \\EXAMPLES:
        \\    lemon run alpine                              # Run VM by name from config
        \\    lemon run --kernel vmlinuz --initrd initrd.img
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
