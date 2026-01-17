const std = @import("std");

pub const ShareConfig = struct {
    host_path: []const u8,
    tag: []const u8,
};

pub const VMConfig = struct {
    name: []const u8,
    kernel: []const u8,
    initrd: ?[]const u8 = null,
    disk: ?[]const u8 = null,
    cmdline: []const u8 = "console=hvc0",
    cpus: u32 = 2,
    memory_mb: u64 = 512,
    shares: []ShareConfig = &[_]ShareConfig{},
    rosetta: bool = false,
};

pub const ConfigFile = struct {
    vms: []VMConfig,
};

pub const ConfigError = error{
    FileNotFound,
    ParseError,
    OutOfMemory,
    InvalidPath,
};

fn getConfigDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return ConfigError.InvalidPath;
    return std.fmt.allocPrint(allocator, "{s}/.config/lemon", .{home});
}

fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return ConfigError.InvalidPath;
    return std.fmt.allocPrint(allocator, "{s}/.config/lemon/vms.json", .{home});
}

pub fn ensureConfigDir(allocator: std.mem.Allocator) !void {
    const config_dir = try getConfigDir(allocator);
    defer allocator.free(config_dir);

    std.fs.cwd().makePath(config_dir) catch {};
}

pub fn loadConfig(allocator: std.mem.Allocator) !ConfigFile {
    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);

    const file = std.fs.cwd().openFile(config_path, .{}) catch {
        return ConfigFile{ .vms = &[_]VMConfig{} };
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return ConfigError.ParseError;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(ConfigFile, allocator, content, .{
        .allocate = .alloc_always,
    }) catch return ConfigError.ParseError;

    return parsed.value;
}

pub fn saveConfig(allocator: std.mem.Allocator, config: ConfigFile) !void {
    try ensureConfigDir(allocator);

    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);

    const file = std.fs.cwd().createFile(config_path, .{}) catch return ConfigError.InvalidPath;
    defer file.close();

    std.json.stringify(config, .{ .whitespace = .indent_2 }, file.writer()) catch return ConfigError.ParseError;
}

pub fn findVM(config: ConfigFile, name: []const u8) ?VMConfig {
    for (config.vms) |vm| {
        if (std.mem.eql(u8, vm.name, name)) {
            return vm;
        }
    }
    return null;
}

pub fn printVMList(config: ConfigFile) void {
    if (config.vms.len == 0) {
        std.debug.print("No VMs configured.\n", .{});
        std.debug.print("Create a VM config at ~/.config/lemon/vms.json\n", .{});
        return;
    }

    std.debug.print("Configured VMs:\n", .{});
    for (config.vms) |vm| {
        std.debug.print("  {s}\n", .{vm.name});
        std.debug.print("    kernel: {s}\n", .{vm.kernel});
        std.debug.print("    cpus: {d}, memory: {d} MB\n", .{ vm.cpus, vm.memory_mb });
    }
}

pub fn printVMDetails(vm: VMConfig) void {
    std.debug.print("VM: {s}\n", .{vm.name});
    std.debug.print("  Kernel:  {s}\n", .{vm.kernel});
    if (vm.initrd) |initrd| {
        std.debug.print("  Initrd:  {s}\n", .{initrd});
    }
    if (vm.disk) |disk| {
        std.debug.print("  Disk:    {s}\n", .{disk});
    }
    std.debug.print("  Cmdline: {s}\n", .{vm.cmdline});
    std.debug.print("  CPUs:    {d}\n", .{vm.cpus});
    std.debug.print("  Memory:  {d} MB\n", .{vm.memory_mb});
    std.debug.print("  Rosetta: {}\n", .{vm.rosetta});
    if (vm.shares.len > 0) {
        std.debug.print("  Shares:\n", .{});
        for (vm.shares) |share| {
            std.debug.print("    {s} -> {s}\n", .{ share.host_path, share.tag });
        }
    }
}

pub fn printExampleConfig() void {
    const example =
        \\Example ~/.config/lemon/vms.json:
        \\{
        \\  "vms": [
        \\    {
        \\      "name": "alpine",
        \\      "kernel": "/path/to/vmlinuz",
        \\      "initrd": "/path/to/initrd",
        \\      "disk": "/path/to/disk.img",
        \\      "cmdline": "console=hvc0",
        \\      "cpus": 2,
        \\      "memory_mb": 1024,
        \\      "rosetta": false,
        \\      "shares": [
        \\        {"host_path": "/Users/me/code", "tag": "code"}
        \\      ]
        \\    }
        \\  ]
        \\}
        \\
    ;
    std.debug.print("{s}", .{example});
}
