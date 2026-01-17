const std = @import("std");
const vz = @import("vz/vz.zig");

pub const Command = union(enum) {
    run: RunOptions,
    create_disk: CreateDiskOptions,
    help,
    version,
};

pub const RunOptions = struct {
    kernel: [:0]const u8,
    initrd: ?[:0]const u8 = null,
    disk: ?[:0]const u8 = null,
    cmdline: [:0]const u8 = "console=hvc0",
    cpus: u32 = 2,
    memory_mb: u64 = 512,
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
    } else if (std.mem.eql(u8, cmd_str, "help") or std.mem.eql(u8, cmd_str, "--help") or std.mem.eql(u8, cmd_str, "-h")) {
        return .help;
    } else if (std.mem.eql(u8, cmd_str, "version") or std.mem.eql(u8, cmd_str, "--version") or std.mem.eql(u8, cmd_str, "-V")) {
        return .version;
    }

    return ParseError.UnknownCommand;
}

fn parseRunCommand(allocator: std.mem.Allocator, args: *std.process.ArgIterator) ParseError!Command {
    var opts = RunOptions{
        .kernel = undefined,
    };
    var has_kernel = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--kernel") or std.mem.eql(u8, arg, "-k")) {
            opts.kernel = args.next() orelse return ParseError.MissingRequiredArg;
            has_kernel = true;
        } else if (std.mem.eql(u8, arg, "--initrd") or std.mem.eql(u8, arg, "-i")) {
            opts.initrd = args.next() orelse return ParseError.MissingRequiredArg;
        } else if (std.mem.eql(u8, arg, "--disk") or std.mem.eql(u8, arg, "-d")) {
            opts.disk = args.next() orelse return ParseError.MissingRequiredArg;
        } else if (std.mem.eql(u8, arg, "--cmdline") or std.mem.eql(u8, arg, "-c")) {
            opts.cmdline = args.next() orelse return ParseError.MissingRequiredArg;
        } else if (std.mem.eql(u8, arg, "--cpus")) {
            const val = args.next() orelse return ParseError.MissingRequiredArg;
            opts.cpus = std.fmt.parseInt(u32, val, 10) catch return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--memory") or std.mem.eql(u8, arg, "-m")) {
            const val = args.next() orelse return ParseError.MissingRequiredArg;
            opts.memory_mb = std.fmt.parseInt(u64, val, 10) catch return ParseError.InvalidValue;
        } else if (!std.mem.startsWith(u8, arg, "-") and !has_kernel) {
            opts.kernel = allocator.dupeZ(u8, arg) catch return ParseError.OutOfMemory;
            has_kernel = true;
        }
    }

    if (!has_kernel) return ParseError.MissingRequiredArg;

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

pub fn printHelp() void {
    const help =
        \\🍋 Lemon - macOS Virtualization.framework CLI
        \\
        \\USAGE:
        \\    lemon <COMMAND> [OPTIONS]
        \\
        \\COMMANDS:
        \\    run             Boot a Linux virtual machine
        \\    create-disk     Create a raw disk image
        \\    help            Show this help message
        \\    version         Show version information
        \\
        \\RUN OPTIONS:
        \\    -k, --kernel <PATH>     Path to Linux kernel (required)
        \\    -i, --initrd <PATH>     Path to initial ramdisk
        \\    -d, --disk <PATH>       Path to disk image
        \\    -c, --cmdline <ARGS>    Kernel command line (default: console=hvc0)
        \\        --cpus <N>          Number of CPUs (default: 2)
        \\    -m, --memory <MB>       Memory in MB (default: 512)
        \\
        \\CREATE-DISK:
        \\    lemon create-disk <PATH> <SIZE_MB>
        \\
        \\EXAMPLES:
        \\    lemon run --kernel vmlinuz --initrd initrd.img
        \\    lemon run -k vmlinuz -d disk.img -m 1024 --cpus 4
        \\    lemon create-disk disk.img 8192
        \\
    ;
    std.debug.print("{s}", .{help});
}

pub fn printVersion() void {
    std.debug.print("lemon 0.1.0\n", .{});
}
