const std = @import("std");

pub const ShareConfig = struct {
    host_path: []const u8,
    tag: []const u8,
};

pub const VMType = enum {
    linux,
    macos,
};

pub const VMConfig = struct {
    name: []const u8,
    vm_type: VMType = .linux,
    kernel: ?[]const u8 = null,
    initrd: ?[]const u8 = null,
    disk: ?[]const u8 = null,
    nvram: ?[]const u8 = null,
    efi: bool = false,
    cmdline: []const u8 = "console=hvc0",
    cpus: u32 = 2,
    memory_mb: u64 = 512,
    shares: []ShareConfig = &[_]ShareConfig{},
    rosetta: bool = false,
    hardware_model: ?[]const u8 = null,
    machine_id: ?[]const u8 = null,
    aux_storage: ?[]const u8 = null,
    display_width: u32 = 1920,
    display_height: u32 = 1080,
};

pub const ConfigFile = struct {
    vms: []VMConfig,
};

pub const ParsedConfig = struct {
    value: ConfigFile,
    arena: ?std.heap.ArenaAllocator,

    pub fn deinit(self: *ParsedConfig) void {
        if (self.arena) |*arena| {
            arena.deinit();
        }
    }
};

pub const ConfigError = error{
    FileNotFound,
    ParseError,
    OutOfMemory,
    InvalidPath,
};

fn getHome() ?[]const u8 {
    return std.posix.getenv("HOME") orelse std.posix.getenv("USERPROFILE");
}

pub fn resolvePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len == 0) return allocator.dupe(u8, path);

    if (path[0] == '~') {
        const home = getHome() orelse {
            const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch return ConfigError.InvalidPath;
            defer allocator.free(cwd);
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ cwd, path[1..] });
        };
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] });
    }

    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path);
    }

    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch return ConfigError.InvalidPath;
    defer allocator.free(cwd);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, path });
}

pub fn normalizeVMConfig(allocator: std.mem.Allocator, vm: VMConfig) !VMConfig {
    var result = vm;

    if (vm.kernel) |k| {
        result.kernel = try resolvePath(allocator, k);
    }
    if (vm.initrd) |i| {
        result.initrd = try resolvePath(allocator, i);
    }
    if (vm.disk) |d| {
        result.disk = try resolvePath(allocator, d);
    }
    if (vm.nvram) |n| {
        result.nvram = try resolvePath(allocator, n);
    }
    if (vm.hardware_model) |h| {
        result.hardware_model = try resolvePath(allocator, h);
    }
    if (vm.machine_id) |m| {
        result.machine_id = try resolvePath(allocator, m);
    }
    if (vm.aux_storage) |a| {
        result.aux_storage = try resolvePath(allocator, a);
    }

    if (vm.shares.len > 0) {
        const new_shares = try allocator.alloc(ShareConfig, vm.shares.len);
        for (vm.shares, 0..) |share, i| {
            new_shares[i] = ShareConfig{
                .host_path = try resolvePath(allocator, share.host_path),
                .tag = try allocator.dupe(u8, share.tag),
            };
        }
        result.shares = new_shares;
    }

    return result;
}

fn getConfigDir(allocator: std.mem.Allocator) ![]const u8 {
    if (getHome()) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.config/lemon", .{home});
    }
    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch return ConfigError.InvalidPath;
    defer allocator.free(cwd);
    return std.fmt.allocPrint(allocator, "{s}/.lemon", .{cwd});
}

fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const config_dir = try getConfigDir(allocator);
    defer allocator.free(config_dir);
    return std.fmt.allocPrint(allocator, "{s}/vms.json", .{config_dir});
}

pub fn getVMDir(allocator: std.mem.Allocator, vm_name: []const u8) ![]const u8 {
    const config_dir = try getConfigDir(allocator);
    defer allocator.free(config_dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ config_dir, vm_name });
}

pub fn ensureVMDir(allocator: std.mem.Allocator, vm_name: []const u8) ![]const u8 {
    const vm_dir = try getVMDir(allocator, vm_name);
    std.fs.cwd().makePath(vm_dir) catch {};
    return vm_dir;
}

pub fn ensureConfigDir(allocator: std.mem.Allocator) !void {
    const config_dir = try getConfigDir(allocator);
    defer allocator.free(config_dir);

    std.fs.cwd().makePath(config_dir) catch {};
}

pub fn loadConfig(allocator: std.mem.Allocator) !ParsedConfig {
    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);

    const file = std.fs.cwd().openFile(config_path, .{}) catch {
        return ParsedConfig{ .value = ConfigFile{ .vms = &[_]VMConfig{} }, .arena = null };
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return ConfigError.ParseError;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(ConfigFile, allocator, content, .{
        .allocate = .alloc_always,
    }) catch return ConfigError.ParseError;

    return .{ .value = parsed.value, .arena = parsed.arena.* };
}

pub fn saveConfig(allocator: std.mem.Allocator, config: ConfigFile) !void {
    try ensureConfigDir(allocator);

    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);

    const json_data = std.json.Stringify.valueAlloc(allocator, config, .{ .whitespace = .indent_2 }) catch return ConfigError.OutOfMemory;
    defer allocator.free(json_data);

    const file = std.fs.cwd().createFile(config_path, .{}) catch return ConfigError.InvalidPath;
    defer file.close();

    file.writeAll(json_data) catch return ConfigError.ParseError;
}

pub fn findVM(config: ConfigFile, name: []const u8) ?VMConfig {
    for (config.vms) |vm| {
        if (std.mem.eql(u8, vm.name, name)) {
            return vm;
        }
    }
    return null;
}

pub fn addVM(allocator: std.mem.Allocator, new_vm: VMConfig) !void {
    var existing = loadConfig(allocator) catch ParsedConfig{ .value = ConfigFile{ .vms = &[_]VMConfig{} }, .arena = null };
    defer existing.deinit();

    for (existing.value.vms) |vm| {
        if (std.mem.eql(u8, vm.name, new_vm.name)) {
            return ConfigError.ParseError;
        }
    }

    const normalized_vm = try normalizeVMConfig(allocator, new_vm);

    const new_vms = try allocator.alloc(VMConfig, existing.value.vms.len + 1);
    defer allocator.free(new_vms);
    @memcpy(new_vms[0..existing.value.vms.len], existing.value.vms);
    new_vms[existing.value.vms.len] = normalized_vm;

    try saveConfig(allocator, ConfigFile{ .vms = new_vms });
}

pub fn removeVM(allocator: std.mem.Allocator, name: []const u8) !bool {
    var existing = try loadConfig(allocator);
    defer existing.deinit();

    var found = false;
    for (existing.value.vms) |vm| {
        if (std.mem.eql(u8, vm.name, name)) {
            found = true;
            break;
        }
    }

    if (!found) return false;

    const new_vms = try allocator.alloc(VMConfig, existing.value.vms.len - 1);
    defer allocator.free(new_vms);
    var idx: usize = 0;
    for (existing.value.vms) |vm| {
        if (!std.mem.eql(u8, vm.name, name)) {
            new_vms[idx] = vm;
            idx += 1;
        }
    }

    try saveConfig(allocator, ConfigFile{ .vms = new_vms });
    return true;
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
        switch (vm.vm_type) {
            .macos => {
                std.debug.print("    type: macOS\n", .{});
            },
            .linux => {
                if (vm.efi) {
                    std.debug.print("    boot: EFI\n", .{});
                } else if (vm.kernel) |k| {
                    std.debug.print("    kernel: {s}\n", .{k});
                }
            },
        }
        std.debug.print("    cpus: {d}, memory: {d} MB\n", .{ vm.cpus, vm.memory_mb });
    }
}

pub fn printVMDetails(vm: VMConfig) void {
    std.debug.print("VM: {s}\n", .{vm.name});
    switch (vm.vm_type) {
        .macos => {
            std.debug.print("  Type:    macOS\n", .{});
            if (vm.disk) |d| {
                std.debug.print("  Disk:    {s}\n", .{d});
            }
            if (vm.aux_storage) |a| {
                std.debug.print("  AuxStorage: {s}\n", .{a});
            }
            std.debug.print("  Display: {d}x{d}\n", .{ vm.display_width, vm.display_height });
        },
        .linux => {
            if (vm.efi) {
                std.debug.print("  Boot:    EFI\n", .{});
            } else if (vm.kernel) |k| {
                std.debug.print("  Kernel:  {s}\n", .{k});
            }
            if (vm.initrd) |initrd| {
                std.debug.print("  Initrd:  {s}\n", .{initrd});
            }
            if (vm.disk) |d| {
                std.debug.print("  Disk:    {s}\n", .{d});
            }
            if (vm.nvram) |nvram| {
                std.debug.print("  NVRAM:   {s}\n", .{nvram});
            }
            if (!vm.efi) {
                std.debug.print("  Cmdline: {s}\n", .{vm.cmdline});
            }
            std.debug.print("  Rosetta: {}\n", .{vm.rosetta});
        },
    }
    std.debug.print("  CPUs:    {d}\n", .{vm.cpus});
    std.debug.print("  Memory:  {d} MB\n", .{vm.memory_mb});
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

test "resolvePath handles absolute paths" {
    const allocator = std.testing.allocator;
    const result = try resolvePath(allocator, "/absolute/path/to/file");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/absolute/path/to/file", result);
}

test "resolvePath handles tilde expansion" {
    const allocator = std.testing.allocator;
    const result = try resolvePath(allocator, "~/some/path");
    defer allocator.free(result);
    const home = std.posix.getenv("HOME") orelse unreachable;
    const expected = try std.fmt.allocPrint(allocator, "{s}/some/path", .{home});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result);
}

test "resolvePath handles relative paths" {
    const allocator = std.testing.allocator;
    const result = try resolvePath(allocator, "relative/path");
    defer allocator.free(result);
    try std.testing.expect(std.fs.path.isAbsolute(result));
    try std.testing.expect(std.mem.endsWith(u8, result, "/relative/path"));
}
