const std = @import("std");
const objc = @import("objc");

pub const VZError = error{
    ClassNotFound,
    AllocationFailed,
    ValidationFailed,
    OperationFailed,
};

pub fn isSupported() bool {
    const VZVirtualMachine = objc.getClass("VZVirtualMachine") orelse return false;
    return VZVirtualMachine.msgSend(bool, objc.sel("isSupported"), .{});
}

pub const Configuration = struct {
    obj: objc.Object,

    pub fn init(cpu_count: u32, memory_size: u64) ?Configuration {
        const VZConfig = objc.getClass("VZVirtualMachineConfiguration") orelse return null;
        const obj = VZConfig.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});
        obj.msgSend(void, objc.sel("setCPUCount:"), .{@as(c_ulong, cpu_count)});
        obj.msgSend(void, objc.sel("setMemorySize:"), .{memory_size});
        return .{ .obj = obj };
    }

    pub fn deinit(self: *Configuration) void {
        self.obj.release();
    }

    pub fn setBootLoader(self: *Configuration, boot_loader: LinuxBootLoader) void {
        self.obj.msgSend(void, objc.sel("setBootLoader:"), .{boot_loader.obj});
    }

    pub fn addStorageDevice(self: *Configuration, storage: Storage) void {
        const NSMutableArray = objc.getClass("NSMutableArray") orelse return;
        const current_devices = self.obj.msgSend(objc.Object, objc.sel("storageDevices"), .{});
        const new_array = NSMutableArray.msgSend(objc.Object, objc.sel("arrayWithArray:"), .{current_devices});
        new_array.msgSend(void, objc.sel("addObject:"), .{storage.obj});
        self.obj.msgSend(void, objc.sel("setStorageDevices:"), .{new_array});
    }

    pub fn addNetworkDevice(self: *Configuration, network: Network) void {
        const NSMutableArray = objc.getClass("NSMutableArray") orelse return;
        const current_devices = self.obj.msgSend(objc.Object, objc.sel("networkDevices"), .{});
        const new_array = NSMutableArray.msgSend(objc.Object, objc.sel("arrayWithArray:"), .{current_devices});
        new_array.msgSend(void, objc.sel("addObject:"), .{network.obj});
        self.obj.msgSend(void, objc.sel("setNetworkDevices:"), .{new_array});
    }

    pub fn addSerialConsole(self: *Configuration) void {
        const VZSerialPort = objc.getClass("VZVirtioConsoleDeviceSerialPortConfiguration") orelse return;
        const VZFileHandleAttachment = objc.getClass("VZFileHandleSerialPortAttachment") orelse return;
        const NSFileHandle = objc.getClass("NSFileHandle") orelse return;

        const stdin_handle = NSFileHandle.msgSend(objc.Object, objc.sel("fileHandleWithStandardInput"), .{});
        const stdout_handle = NSFileHandle.msgSend(objc.Object, objc.sel("fileHandleWithStandardOutput"), .{});

        const attachment = VZFileHandleAttachment.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("initWithFileHandleForReading:fileHandleForWriting:"), .{ stdin_handle, stdout_handle });

        const serial_port = VZSerialPort.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});
        serial_port.msgSend(void, objc.sel("setAttachment:"), .{attachment});

        const NSArray = objc.getClass("NSArray") orelse return;
        const ports_array = NSArray.msgSend(objc.Object, objc.sel("arrayWithObject:"), .{serial_port});
        self.obj.msgSend(void, objc.sel("setSerialPorts:"), .{ports_array});
    }

    pub fn addEntropy(self: *Configuration) void {
        const VZEntropy = objc.getClass("VZVirtioEntropyDeviceConfiguration") orelse return;
        const NSArray = objc.getClass("NSArray") orelse return;

        const entropy = VZEntropy.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});
        const entropy_array = NSArray.msgSend(objc.Object, objc.sel("arrayWithObject:"), .{entropy});
        self.obj.msgSend(void, objc.sel("setEntropyDevices:"), .{entropy_array});
    }

    pub fn validate(self: *Configuration) !void {
        _ = self;
    }
};

pub const LinuxBootLoader = struct {
    obj: objc.Object,

    pub fn init(kernel_path: [:0]const u8, initrd_path: ?[:0]const u8, command_line: ?[:0]const u8) ?LinuxBootLoader {
        const VZLinuxBootLoader = objc.getClass("VZLinuxBootLoader") orelse return null;
        const NSURL = objc.getClass("NSURL") orelse return null;

        const kernel_url = NSURL.msgSend(objc.Object, objc.sel("fileURLWithPath:"), .{
            toNSString(kernel_path) orelse return null,
        });

        const obj = VZLinuxBootLoader.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("initWithKernelURL:"), .{kernel_url});

        if (initrd_path) |path| {
            const initrd_url = NSURL.msgSend(objc.Object, objc.sel("fileURLWithPath:"), .{
                toNSString(path) orelse return null,
            });
            obj.msgSend(void, objc.sel("setInitialRamdiskURL:"), .{initrd_url});
        }

        if (command_line) |cmd| {
            obj.msgSend(void, objc.sel("setCommandLine:"), .{toNSString(cmd) orelse return null});
        }

        return .{ .obj = obj };
    }

    pub fn deinit(self: *LinuxBootLoader) void {
        self.obj.release();
    }
};

pub const Storage = struct {
    obj: objc.Object,

    pub fn initDiskImage(path: [:0]const u8, read_only: bool) ?Storage {
        const VZDiskAttachment = objc.getClass("VZDiskImageStorageDeviceAttachment") orelse return null;
        const VZBlockDevice = objc.getClass("VZVirtioBlockDeviceConfiguration") orelse return null;
        const NSURL = objc.getClass("NSURL") orelse return null;

        const disk_url = NSURL.msgSend(objc.Object, objc.sel("fileURLWithPath:"), .{
            toNSString(path) orelse return null,
        });

        const attachment = VZDiskAttachment.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(?objc.Object, objc.sel("initWithURL:readOnly:error:"), .{ disk_url, read_only, @as(?*anyopaque, null) }) orelse return null;

        const block_device = VZBlockDevice.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("initWithAttachment:"), .{attachment});

        return .{ .obj = block_device };
    }

    pub fn deinit(self: *Storage) void {
        self.obj.release();
    }
};

pub const Network = struct {
    obj: objc.Object,

    pub fn initNAT() ?Network {
        const VZNATAttachment = objc.getClass("VZNATNetworkDeviceAttachment") orelse return null;
        const VZNetworkDevice = objc.getClass("VZVirtioNetworkDeviceConfiguration") orelse return null;
        const VZMACAddress = objc.getClass("VZMACAddress") orelse return null;

        const attachment = VZNATAttachment.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});

        const network_device = VZNetworkDevice.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});
        network_device.msgSend(void, objc.sel("setAttachment:"), .{attachment});

        const mac_address = VZMACAddress.msgSend(objc.Object, objc.sel("randomLocallyAdministeredAddress"), .{});
        network_device.msgSend(void, objc.sel("setMACAddress:"), .{mac_address});

        return .{ .obj = network_device };
    }

    pub fn deinit(self: *Network) void {
        self.obj.release();
    }
};

pub const VMState = enum(c_long) {
    stopped = 0,
    running = 1,
    paused = 2,
    @"error" = 3,
    starting = 4,
    pausing = 5,
    resuming = 6,
    stopping = 7,
    saving = 8,
    restoring = 9,
};

pub const VirtualMachine = struct {
    obj: objc.Object,

    pub fn init(config: Configuration) ?VirtualMachine {
        const VZVirtualMachine = objc.getClass("VZVirtualMachine") orelse return null;

        const obj = VZVirtualMachine.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("initWithConfiguration:"), .{config.obj});

        return .{ .obj = obj };
    }

    pub fn deinit(self: *VirtualMachine) void {
        self.obj.release();
    }

    pub fn state(self: *VirtualMachine) VMState {
        const raw_state = self.obj.msgSend(c_long, objc.sel("state"), .{});
        return @enumFromInt(raw_state);
    }
};

fn toNSString(str: [:0]const u8) ?objc.Object {
    const NSString = objc.getClass("NSString") orelse return null;
    return NSString.msgSend(objc.Object, objc.sel("stringWithUTF8String:"), .{str.ptr});
}

test "isSupported" {
    _ = isSupported();
}
