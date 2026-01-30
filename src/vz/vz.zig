const std = @import("std");
pub const objc = @import("objc");

pub const runloop = @import("runloop.zig");
pub const RunLoop = runloop.RunLoop;

pub const appkit = @import("appkit.zig");
pub const NSApplication = appkit.NSApplication;
pub const NSWindow = appkit.NSWindow;
pub const NSImage = appkit.NSImage;
pub const NSRect = appkit.NSRect;
pub const NSPoint = appkit.NSPoint;
pub const NSSize = appkit.NSSize;
pub const VirtualMachineView = appkit.VirtualMachineView;

pub const VZError = error{
    ClassNotFound,
    AllocationFailed,
    ValidationFailed,
    OperationFailed,
};

pub fn isSupported() bool {
    const vz_virtual_machine = objc.getClass("VZVirtualMachine") orelse return false;
    return vz_virtual_machine.msgSend(bool, objc.sel("isSupported"), .{});
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

    pub fn deinit(self: Configuration) void {
        self.obj.release();
    }

    pub fn setBootLoader(self: Configuration, boot_loader: LinuxBootLoader) void {
        self.obj.msgSend(void, objc.sel("setBootLoader:"), .{boot_loader.obj});
    }

    pub fn setEFIBootLoader(self: Configuration, boot_loader: EFIBootLoader) void {
        self.obj.msgSend(void, objc.sel("setBootLoader:"), .{boot_loader.obj});
    }

    pub fn setMacOSBootLoader(self: Configuration, boot_loader: MacOSBootLoader) void {
        self.obj.msgSend(void, objc.sel("setBootLoader:"), .{boot_loader.obj});
    }

    pub fn setPlatform(self: Configuration, platform: GenericPlatformConfiguration) void {
        self.obj.msgSend(void, objc.sel("setPlatform:"), .{platform.obj});
    }

    pub fn setMacPlatform(self: Configuration, platform: MacPlatformConfiguration) void {
        self.obj.msgSend(void, objc.sel("setPlatform:"), .{platform.obj});
    }

    pub fn addUSBStorage(self: Configuration, storage: USBStorage) void {
        const NSMutableArray = objc.getClass("NSMutableArray") orelse return;
        const current_devices = self.obj.msgSend(objc.Object, objc.sel("storageDevices"), .{});
        const new_array = NSMutableArray.msgSend(objc.Object, objc.sel("arrayWithArray:"), .{current_devices});
        new_array.msgSend(void, objc.sel("addObject:"), .{storage.obj});
        self.obj.msgSend(void, objc.sel("setStorageDevices:"), .{new_array});
    }

    pub fn addStorageDevice(self: Configuration, storage: Storage) void {
        const NSMutableArray = objc.getClass("NSMutableArray") orelse return;
        const current_devices = self.obj.msgSend(objc.Object, objc.sel("storageDevices"), .{});
        const new_array = NSMutableArray.msgSend(objc.Object, objc.sel("arrayWithArray:"), .{current_devices});
        new_array.msgSend(void, objc.sel("addObject:"), .{storage.obj});
        self.obj.msgSend(void, objc.sel("setStorageDevices:"), .{new_array});
    }

    pub fn addNetworkDevice(self: Configuration, network: Network) void {
        const NSMutableArray = objc.getClass("NSMutableArray") orelse return;
        const current_devices = self.obj.msgSend(objc.Object, objc.sel("networkDevices"), .{});
        const new_array = NSMutableArray.msgSend(objc.Object, objc.sel("arrayWithArray:"), .{current_devices});
        new_array.msgSend(void, objc.sel("addObject:"), .{network.obj});
        self.obj.msgSend(void, objc.sel("setNetworkDevices:"), .{new_array});
    }

    pub fn addSerialConsole(self: Configuration) void {
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

    pub fn addEntropy(self: Configuration) void {
        const VZEntropy = objc.getClass("VZVirtioEntropyDeviceConfiguration") orelse return;
        const NSArray = objc.getClass("NSArray") orelse return;

        const entropy = VZEntropy.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});
        const entropy_array = NSArray.msgSend(objc.Object, objc.sel("arrayWithObject:"), .{entropy});
        self.obj.msgSend(void, objc.sel("setEntropyDevices:"), .{entropy_array});
    }

    pub fn addMemoryBalloon(self: Configuration) void {
        const VZBalloon = objc.getClass("VZVirtioTraditionalMemoryBalloonDeviceConfiguration") orelse return;
        const NSArray = objc.getClass("NSArray") orelse return;

        const balloon = VZBalloon.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});
        const balloon_array = NSArray.msgSend(objc.Object, objc.sel("arrayWithObject:"), .{balloon});
        self.obj.msgSend(void, objc.sel("setMemoryBalloonDevices:"), .{balloon_array});
    }

    pub fn addSocketDevice(self: Configuration, socket: VirtioSocket) void {
        const NSMutableArray = objc.getClass("NSMutableArray") orelse return;
        const current_devices = self.obj.msgSend(objc.Object, objc.sel("socketDevices"), .{});
        const new_array = NSMutableArray.msgSend(objc.Object, objc.sel("arrayWithArray:"), .{current_devices});
        new_array.msgSend(void, objc.sel("addObject:"), .{socket.obj});
        self.obj.msgSend(void, objc.sel("setSocketDevices:"), .{new_array});
    }

    pub fn addAudioDevice(self: Configuration, sound: VirtioSound) void {
        const NSMutableArray = objc.getClass("NSMutableArray") orelse return;
        const current_devices = self.obj.msgSend(objc.Object, objc.sel("audioDevices"), .{});
        const new_array = NSMutableArray.msgSend(objc.Object, objc.sel("arrayWithArray:"), .{current_devices});
        new_array.msgSend(void, objc.sel("addObject:"), .{sound.obj});
        self.obj.msgSend(void, objc.sel("setAudioDevices:"), .{new_array});
    }

    pub fn addDirectoryShare(self: Configuration, share: SharedDirectory) void {
        const NSMutableArray = objc.getClass("NSMutableArray") orelse return;
        const current_devices = self.obj.msgSend(objc.Object, objc.sel("directorySharingDevices"), .{});
        const new_array = NSMutableArray.msgSend(objc.Object, objc.sel("arrayWithArray:"), .{current_devices});
        new_array.msgSend(void, objc.sel("addObject:"), .{share.obj});
        self.obj.msgSend(void, objc.sel("setDirectorySharingDevices:"), .{new_array});
    }

    pub fn addRosettaShare(self: Configuration, share: RosettaShare) void {
        const NSMutableArray = objc.getClass("NSMutableArray") orelse return;
        const current_devices = self.obj.msgSend(objc.Object, objc.sel("directorySharingDevices"), .{});
        const new_array = NSMutableArray.msgSend(objc.Object, objc.sel("arrayWithArray:"), .{current_devices});
        new_array.msgSend(void, objc.sel("addObject:"), .{share.obj});
        self.obj.msgSend(void, objc.sel("setDirectorySharingDevices:"), .{new_array});
    }

    pub fn addGraphicsDevice(self: Configuration, graphics: VirtioGraphicsDevice) void {
        const NSMutableArray = objc.getClass("NSMutableArray") orelse return;
        const current_devices = self.obj.msgSend(objc.Object, objc.sel("graphicsDevices"), .{});
        const new_array = NSMutableArray.msgSend(objc.Object, objc.sel("arrayWithArray:"), .{current_devices});
        new_array.msgSend(void, objc.sel("addObject:"), .{graphics.obj});
        self.obj.msgSend(void, objc.sel("setGraphicsDevices:"), .{new_array});
    }

    pub fn addMacGraphicsDevice(self: Configuration, graphics: MacGraphicsDevice) void {
        const NSMutableArray = objc.getClass("NSMutableArray") orelse return;
        const current_devices = self.obj.msgSend(objc.Object, objc.sel("graphicsDevices"), .{});
        const new_array = NSMutableArray.msgSend(objc.Object, objc.sel("arrayWithArray:"), .{current_devices});
        new_array.msgSend(void, objc.sel("addObject:"), .{graphics.obj});
        self.obj.msgSend(void, objc.sel("setGraphicsDevices:"), .{new_array});
    }

    pub fn addKeyboard(self: Configuration) void {
        const VZUSBKeyboard = objc.getClass("VZUSBKeyboardConfiguration") orelse return;
        const NSArray = objc.getClass("NSArray") orelse return;

        const keyboard = VZUSBKeyboard.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});
        const keyboards_array = NSArray.msgSend(objc.Object, objc.sel("arrayWithObject:"), .{keyboard});
        self.obj.msgSend(void, objc.sel("setKeyboards:"), .{keyboards_array});
    }

    pub fn addPointingDevice(self: Configuration) void {
        const VZUSBPointing = objc.getClass("VZUSBScreenCoordinatePointingDeviceConfiguration") orelse return;
        const NSArray = objc.getClass("NSArray") orelse return;

        const pointing = VZUSBPointing.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});
        const pointing_array = NSArray.msgSend(objc.Object, objc.sel("arrayWithObject:"), .{pointing});
        self.obj.msgSend(void, objc.sel("setPointingDevices:"), .{pointing_array});
    }

    pub fn addVirtioKeyboard(self: Configuration) void {
        const VZVirtioKeyboard = objc.getClass("VZVirtioKeyboardConfiguration") orelse return;
        const NSArray = objc.getClass("NSArray") orelse return;

        const keyboard = VZVirtioKeyboard.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});
        const keyboards_array = NSArray.msgSend(objc.Object, objc.sel("arrayWithObject:"), .{keyboard});
        self.obj.msgSend(void, objc.sel("setKeyboards:"), .{keyboards_array});
    }

    pub fn addVirtioPointingDevice(self: Configuration) void {
        const VZVirtioPointing = objc.getClass("VZVirtioPointingDeviceConfiguration") orelse return;
        const NSArray = objc.getClass("NSArray") orelse return;

        const pointing = VZVirtioPointing.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});
        const pointing_array = NSArray.msgSend(objc.Object, objc.sel("arrayWithObject:"), .{pointing});
        self.obj.msgSend(void, objc.sel("setPointingDevices:"), .{pointing_array});
    }

    pub fn addUSBController(self: Configuration) void {
        const VZXHCIController = objc.getClass("VZXHCIControllerConfiguration") orelse return;
        const NSArray = objc.getClass("NSArray") orelse return;

        const controller = VZXHCIController.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});
        const controller_array = NSArray.msgSend(objc.Object, objc.sel("arrayWithObject:"), .{controller});
        self.obj.msgSend(void, objc.sel("setUsbControllers:"), .{controller_array});
    }

    pub fn validate(self: Configuration) bool {
        var error_ptr: objc.c.id = null;
        const valid = self.obj.msgSend(bool, objc.sel("validateWithError:"), .{&error_ptr});
        if (!valid) {
            if (error_ptr) |err_raw| {
                const err = objc.Object{ .value = err_raw };
                const desc = err.msgSend(objc.Object, objc.sel("localizedDescription"), .{});
                const cstr = desc.msgSend([*:0]const u8, objc.sel("UTF8String"), .{});
                std.debug.print("Validation error: {s}\n", .{cstr});
            } else {
                std.debug.print("Validation failed (no error details)\n", .{});
            }
        }
        return valid;
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

/// EFI Variable Store - persists UEFI variables between boots
pub const EFIVariableStore = struct {
    obj: objc.Object,

    /// Create a new EFI variable store at the given path
    pub fn create(path: [:0]const u8) ?EFIVariableStore {
        const VZEFIVariableStore = objc.getClass("VZEFIVariableStore") orelse return null;
        const NSURL = objc.getClass("NSURL") orelse return null;

        const path_str = toNSString(path) orelse return null;
        const url = NSURL.msgSend(objc.Object, objc.sel("fileURLWithPath:"), .{path_str});

        // Use raw msgSend to work around zig-objc optional return type issue
        const c = @import("objc").c;
        const MsgSendFn = *const fn (c.id, c.SEL, c.id, c_ulong, ?*anyopaque) callconv(.c) c.id;
        const msg_send_fn: MsgSendFn = @ptrCast(&c.objc_msgSend);

        const allocated = VZEFIVariableStore.msgSend(objc.Object, objc.sel("alloc"), .{});
        const raw_obj = msg_send_fn(
            allocated.value,
            objc.sel("initCreatingVariableStoreAtURL:options:error:").value,
            url.value,
            0,
            null,
        );

        if (raw_obj == null) return null;
        return .{ .obj = objc.Object{ .value = raw_obj.? } };
    }

    /// Load an existing EFI variable store from the given path
    pub fn load(path: [:0]const u8) ?EFIVariableStore {
        const VZEFIVariableStore = objc.getClass("VZEFIVariableStore") orelse return null;
        const NSURL = objc.getClass("NSURL") orelse return null;

        const path_str = toNSString(path) orelse return null;
        const url = NSURL.msgSend(objc.Object, objc.sel("fileURLWithPath:"), .{path_str});

        // Use raw msgSend to work around zig-objc optional return type issue
        const c = @import("objc").c;
        const MsgSendFn = *const fn (c.id, c.SEL, c.id) callconv(.c) c.id;
        const msg_send_fn: MsgSendFn = @ptrCast(&c.objc_msgSend);

        const allocated = VZEFIVariableStore.msgSend(objc.Object, objc.sel("alloc"), .{});
        const raw_obj = msg_send_fn(
            allocated.value,
            objc.sel("initWithURL:").value,
            url.value,
        );

        if (raw_obj == null) return null;
        return .{ .obj = objc.Object{ .value = raw_obj.? } };
    }

    pub fn deinit(self: *EFIVariableStore) void {
        self.obj.release();
    }
};

/// EFI Boot Loader - boots via UEFI firmware (required for ISO boot)
pub const EFIBootLoader = struct {
    obj: objc.Object,

    pub fn init(variable_store: EFIVariableStore) ?EFIBootLoader {
        const VZEFIBootLoader = objc.getClass("VZEFIBootLoader") orelse return null;

        const obj = VZEFIBootLoader.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});

        // Use raw msgSend to set the variable store
        const c = @import("objc").c;
        const SetterFn = *const fn (c.id, c.SEL, c.id) callconv(.c) void;
        const setter_fn: SetterFn = @ptrCast(&c.objc_msgSend);
        setter_fn(
            obj.value,
            objc.sel("setVariableStore:").value,
            variable_store.obj.value,
        );

        return .{ .obj = obj };
    }

    pub fn deinit(self: *EFIBootLoader) void {
        self.obj.release();
    }
};

/// Generic Platform Configuration - for Linux VMs on ARM64
pub const GenericPlatformConfiguration = struct {
    obj: objc.Object,

    pub fn init() ?GenericPlatformConfiguration {
        const VZGenericPlatformConfiguration = objc.getClass("VZGenericPlatformConfiguration") orelse return null;

        const obj = VZGenericPlatformConfiguration.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});

        return .{ .obj = obj };
    }

    pub fn deinit(self: *GenericPlatformConfiguration) void {
        self.obj.release();
    }
};

/// Check if macOS virtualization is supported on this host
pub fn isMacOSVMSupported() bool {
    const vz_macos_restore_image = objc.getClass("VZMacOSRestoreImage") orelse return false;
    _ = vz_macos_restore_image;
    return true;
}

/// Mac Hardware Model - describes the virtual Mac hardware
pub const MacHardwareModel = struct {
    obj: objc.Object,

    /// Create from data representation (for restoring saved VMs)
    pub fn initFromData(data: objc.Object) ?MacHardwareModel {
        const VZMacHardwareModel = objc.getClass("VZMacHardwareModel") orelse return null;

        const c = @import("objc").c;
        const MsgSendFn = *const fn (c.id, c.SEL, c.id) callconv(.c) c.id;
        const msg_send_fn: MsgSendFn = @ptrCast(&c.objc_msgSend);

        const allocated = VZMacHardwareModel.msgSend(objc.Object, objc.sel("alloc"), .{});
        const raw_obj = msg_send_fn(
            allocated.value,
            objc.sel("initWithDataRepresentation:").value,
            data.value,
        );

        if (raw_obj == null) return null;
        return .{ .obj = objc.Object{ .value = raw_obj.? } };
    }

    /// Get the data representation for saving
    pub fn dataRepresentation(self: MacHardwareModel) objc.Object {
        return self.obj.msgSend(objc.Object, objc.sel("dataRepresentation"), .{});
    }

    /// Check if this hardware model is supported on the current host
    pub fn isSupported(self: MacHardwareModel) bool {
        return self.obj.msgSend(bool, objc.sel("isSupported"), .{});
    }

    pub fn deinit(self: MacHardwareModel) void {
        self.obj.release();
    }
};

/// Mac Machine Identifier - unique identifier for a virtual Mac
pub const MacMachineIdentifier = struct {
    obj: objc.Object,

    /// Create a new random machine identifier
    pub fn init() ?MacMachineIdentifier {
        const VZMacMachineIdentifier = objc.getClass("VZMacMachineIdentifier") orelse return null;

        const obj = VZMacMachineIdentifier.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});

        return .{ .obj = obj };
    }

    /// Create from data representation (for restoring saved VMs)
    pub fn initFromData(data: objc.Object) ?MacMachineIdentifier {
        const VZMacMachineIdentifier = objc.getClass("VZMacMachineIdentifier") orelse return null;

        const c = @import("objc").c;
        const MsgSendFn = *const fn (c.id, c.SEL, c.id) callconv(.c) c.id;
        const msg_send_fn: MsgSendFn = @ptrCast(&c.objc_msgSend);

        const allocated = VZMacMachineIdentifier.msgSend(objc.Object, objc.sel("alloc"), .{});
        const raw_obj = msg_send_fn(
            allocated.value,
            objc.sel("initWithDataRepresentation:").value,
            data.value,
        );

        if (raw_obj == null) return null;
        return .{ .obj = objc.Object{ .value = raw_obj.? } };
    }

    /// Get the data representation for saving
    pub fn dataRepresentation(self: MacMachineIdentifier) objc.Object {
        return self.obj.msgSend(objc.Object, objc.sel("dataRepresentation"), .{});
    }

    pub fn deinit(self: MacMachineIdentifier) void {
        self.obj.release();
    }
};

/// Mac Auxiliary Storage - stores macOS-specific data (NVRAM, etc.)
pub const MacAuxiliaryStorage = struct {
    obj: objc.Object,

    /// Create new auxiliary storage at the given path
    pub fn create(path: [:0]const u8, hardware_model: MacHardwareModel) ?MacAuxiliaryStorage {
        const VZMacAuxiliaryStorage = objc.getClass("VZMacAuxiliaryStorage") orelse return null;
        const NSURL = objc.getClass("NSURL") orelse return null;

        const path_str = toNSString(path) orelse return null;
        const url = NSURL.msgSend(objc.Object, objc.sel("fileURLWithPath:"), .{path_str});

        const c = @import("objc").c;
        const MsgSendFn = *const fn (c.id, c.SEL, c.id, c.id, c_ulong, ?*anyopaque) callconv(.c) c.id;
        const msg_send_fn: MsgSendFn = @ptrCast(&c.objc_msgSend);

        const allocated = VZMacAuxiliaryStorage.msgSend(objc.Object, objc.sel("alloc"), .{});
        const raw_obj = msg_send_fn(
            allocated.value,
            objc.sel("initCreatingStorageAtURL:hardwareModel:options:error:").value,
            url.value,
            hardware_model.obj.value,
            0, // no options
            null,
        );

        if (raw_obj == null) return null;
        return .{ .obj = objc.Object{ .value = raw_obj.? } };
    }

    /// Load existing auxiliary storage from the given path
    pub fn load(path: [:0]const u8) ?MacAuxiliaryStorage {
        const VZMacAuxiliaryStorage = objc.getClass("VZMacAuxiliaryStorage") orelse return null;
        const NSURL = objc.getClass("NSURL") orelse return null;

        const path_str = toNSString(path) orelse return null;
        const url = NSURL.msgSend(objc.Object, objc.sel("fileURLWithPath:"), .{path_str});

        const obj = VZMacAuxiliaryStorage.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("initWithURL:"), .{url});

        return .{ .obj = obj };
    }

    pub fn deinit(self: MacAuxiliaryStorage) void {
        self.obj.release();
    }
};

/// Mac Platform Configuration - platform config for macOS VMs on Apple Silicon
pub const MacPlatformConfiguration = struct {
    obj: objc.Object,

    /// Create a new macOS platform configuration
    pub fn init(
        hardware_model: MacHardwareModel,
        machine_identifier: MacMachineIdentifier,
        auxiliary_storage: MacAuxiliaryStorage,
    ) ?MacPlatformConfiguration {
        const VZMacPlatformConfiguration = objc.getClass("VZMacPlatformConfiguration") orelse return null;

        const obj = VZMacPlatformConfiguration.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});

        obj.msgSend(void, objc.sel("setHardwareModel:"), .{hardware_model.obj});
        obj.msgSend(void, objc.sel("setMachineIdentifier:"), .{machine_identifier.obj});
        obj.msgSend(void, objc.sel("setAuxiliaryStorage:"), .{auxiliary_storage.obj});

        return .{ .obj = obj };
    }

    pub fn deinit(self: MacPlatformConfiguration) void {
        self.obj.release();
    }
};

/// macOS Boot Loader - boots macOS guests
pub const MacOSBootLoader = struct {
    obj: objc.Object,

    pub fn init() ?MacOSBootLoader {
        const VZMacOSBootLoader = objc.getClass("VZMacOSBootLoader") orelse return null;

        const obj = VZMacOSBootLoader.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});

        return .{ .obj = obj };
    }

    pub fn deinit(self: MacOSBootLoader) void {
        self.obj.release();
    }
};

/// Mac Graphics Device - Metal-accelerated graphics for macOS guests
pub const MacGraphicsDevice = struct {
    obj: objc.Object,

    /// Create a Mac graphics device with a single display
    pub fn init(width: u32, height: u32, ppi: u32) ?MacGraphicsDevice {
        const VZMacGraphicsDeviceConfiguration = objc.getClass("VZMacGraphicsDeviceConfiguration") orelse return null;
        const VZMacGraphicsDisplayConfiguration = objc.getClass("VZMacGraphicsDisplayConfiguration") orelse return null;
        const NSArray = objc.getClass("NSArray") orelse return null;

        const display = VZMacGraphicsDisplayConfiguration.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("initWithWidthInPixels:heightInPixels:pixelsPerInch:"), .{
            @as(c_long, width),
            @as(c_long, height),
            @as(c_long, ppi),
        });

        const displays_array = NSArray.msgSend(objc.Object, objc.sel("arrayWithObject:"), .{display});

        const graphics_device = VZMacGraphicsDeviceConfiguration.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});
        graphics_device.msgSend(void, objc.sel("setDisplays:"), .{displays_array});

        return .{ .obj = graphics_device };
    }

    pub fn deinit(self: MacGraphicsDevice) void {
        self.obj.release();
    }
};

/// macOS Restore Image - represents a macOS installer image (.ipsw)
pub const MacOSRestoreImage = struct {
    obj: objc.Object,

    /// Get the hardware model required by this restore image
    pub fn mostFeaturefulSupportedConfiguration(self: MacOSRestoreImage) ?MacOSConfigurationRequirements {
        const c = objc.c;
        const MsgSendFn = *const fn (c.id, c.SEL) callconv(.c) c.id;
        const msg_send_fn: MsgSendFn = @ptrCast(&c.objc_msgSend);

        const config = msg_send_fn(self.obj.value, objc.sel("mostFeaturefulSupportedConfiguration").value);
        if (config == null) return null;
        return .{ .obj = objc.Object{ .value = config } };
    }

    /// Get the build version string
    pub fn buildVersion(self: MacOSRestoreImage) ?[*:0]const u8 {
        const c = objc.c;
        const MsgSendFn = *const fn (c.id, c.SEL) callconv(.c) c.id;
        const msg_send_fn: MsgSendFn = @ptrCast(&c.objc_msgSend);

        const ns_string = msg_send_fn(self.obj.value, objc.sel("buildVersion").value);
        if (ns_string == null) return null;

        const StringMsgSendFn = *const fn (c.id, c.SEL) callconv(.c) [*:0]const u8;
        const str_msg_send: StringMsgSendFn = @ptrCast(&c.objc_msgSend);
        return str_msg_send(ns_string, objc.sel("UTF8String").value);
    }

    /// Get the URL of the restore image
    pub fn url(self: MacOSRestoreImage) ?[*:0]const u8 {
        const c = objc.c;
        const MsgSendFn = *const fn (c.id, c.SEL) callconv(.c) c.id;
        const msg_send_fn: MsgSendFn = @ptrCast(&c.objc_msgSend);

        const ns_url = msg_send_fn(self.obj.value, objc.sel("URL").value);
        if (ns_url == null) return null;

        const ns_string = msg_send_fn(ns_url, objc.sel("absoluteString").value);
        if (ns_string == null) return null;

        const StringMsgSendFn = *const fn (c.id, c.SEL) callconv(.c) [*:0]const u8;
        const str_msg_send: StringMsgSendFn = @ptrCast(&c.objc_msgSend);
        return str_msg_send(ns_string, objc.sel("UTF8String").value);
    }

    pub fn deinit(self: MacOSRestoreImage) void {
        self.obj.release();
    }
};

/// macOS Configuration Requirements - requirements for running a macOS version
pub const MacOSConfigurationRequirements = struct {
    obj: objc.Object,

    /// Get the hardware model for this configuration
    pub fn hardwareModel(self: MacOSConfigurationRequirements) ?MacHardwareModel {
        const c = objc.c;
        const MsgSendFn = *const fn (c.id, c.SEL) callconv(.c) c.id;
        const msg_send_fn: MsgSendFn = @ptrCast(&c.objc_msgSend);

        const hw = msg_send_fn(self.obj.value, objc.sel("hardwareModel").value);
        if (hw == null) return null;

        const RetainFn = *const fn (c.id, c.SEL) callconv(.c) c.id;
        const retain_fn: RetainFn = @ptrCast(&c.objc_msgSend);
        _ = retain_fn(hw, objc.sel("retain").value);

        return .{ .obj = objc.Object{ .value = hw } };
    }

    /// Get minimum supported CPU count
    pub fn minimumSupportedCPUCount(self: MacOSConfigurationRequirements) u64 {
        return self.obj.msgSend(u64, objc.sel("minimumSupportedCPUCount"), .{});
    }

    /// Get minimum supported memory size
    pub fn minimumSupportedMemorySize(self: MacOSConfigurationRequirements) u64 {
        return self.obj.msgSend(u64, objc.sel("minimumSupportedMemorySize"), .{});
    }

    pub fn deinit(self: MacOSConfigurationRequirements) void {
        self.obj.release();
    }
};

/// Callback context for async macOS operations
const MacOSAsyncContext = struct {
    result: *std.atomic.Value(AsyncResult),
    restore_image: ?*MacOSRestoreImage = null,
};

pub const AsyncResult = enum(u8) {
    success,
    failed,
    pending,
};

const MacOSRestoreImageBlock = objc.Block(MacOSAsyncContext, .{ objc.c.id, ?*anyopaque }, void);

fn restoreImageCompletionHandler(ctx: *const MacOSRestoreImageBlock.Context, image: objc.c.id, err: ?*anyopaque) callconv(.c) void {
    if (err) |err_ptr| {
        const err_obj = objc.Object{ .value = @ptrCast(@alignCast(err_ptr)) };
        const desc = err_obj.msgSend(objc.Object, objc.sel("localizedDescription"), .{});
        const cstr = desc.msgSend([*:0]const u8, objc.sel("UTF8String"), .{});
        std.debug.print("  Restore image error: {s}\n", .{cstr});
        ctx.result.store(.failed, .release);
    } else if (image == null) {
        std.debug.print("  Restore image returned null.\n", .{});
        ctx.result.store(.failed, .release);
    } else {
        if (ctx.restore_image) |out| {
            const img_obj = objc.Object{ .value = image };
            _ = img_obj.retain();
            out.* = .{ .obj = img_obj };
        }
        ctx.result.store(.success, .release);
    }
}

/// Fetch the latest supported macOS restore image URL
pub fn fetchLatestSupportedRestoreImage() ?MacOSRestoreImage {
    const vz_macos_restore_image = objc.getClass("VZMacOSRestoreImage") orelse return null;

    var result = std.atomic.Value(AsyncResult).init(.pending);
    var restore_image: MacOSRestoreImage = undefined;

    var block = MacOSRestoreImageBlock.init(.{
        .result = &result,
        .restore_image = &restore_image,
    }, &restoreImageCompletionHandler);

    vz_macos_restore_image.msgSend(void, objc.sel("fetchLatestSupportedWithCompletionHandler:"), .{&block});

    var run_loop = RunLoop.current() orelse return null;
    while (result.load(.acquire) == .pending) {
        run_loop.runOnce();
    }

    if (result.load(.acquire) == .success) {
        return restore_image;
    }
    return null;
}

/// Load a macOS restore image from a local file
pub fn loadRestoreImage(path: [:0]const u8) ?MacOSRestoreImage {
    std.fs.cwd().access(path, .{}) catch {
        std.debug.print("Error: IPSW file not found: {s}\n", .{path});
        return null;
    };

    const vz_macos_restore_image = objc.getClass("VZMacOSRestoreImage") orelse return null;
    const ns_url = objc.getClass("NSURL") orelse return null;

    const path_str = toNSString(path) orelse return null;
    const url = ns_url.msgSend(objc.Object, objc.sel("fileURLWithPath:"), .{path_str});

    var result = std.atomic.Value(AsyncResult).init(.pending);
    var restore_image: MacOSRestoreImage = undefined;

    var block = MacOSRestoreImageBlock.init(.{
        .result = &result,
        .restore_image = &restore_image,
    }, &restoreImageCompletionHandler);

    vz_macos_restore_image.msgSend(void, objc.sel("loadFileURL:completionHandler:"), .{ url, &block });

    var run_loop = RunLoop.current() orelse return null;
    while (result.load(.acquire) == .pending) {
        run_loop.runOnce();
    }

    if (result.load(.acquire) == .success) {
        return restore_image;
    }
    return null;
}

/// Download a file from a URL to a local path using curl
pub fn downloadFile(url_str: [*:0]const u8, dest_path: [:0]const u8, progress_callback: ?*const fn (f64) void) bool {
    _ = progress_callback;

    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{
            "/usr/bin/curl",
            "-L",
            "-#",
            "-f",
            "-o",
            dest_path,
            std.mem.span(url_str),
        },
    }) catch return false;

    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    return result.term.Exited == 0;
}

/// macOS Installer - installs macOS into a VM
pub const MacOSInstaller = struct {
    obj: objc.Object,
    progress: objc.Object,

    pub fn init(vm: VirtualMachine, restore_image_path: [:0]const u8) ?MacOSInstaller {
        const VZMacOSInstaller = objc.getClass("VZMacOSInstaller") orelse return null;
        const NSURL = objc.getClass("NSURL") orelse return null;

        const path_str = toNSString(restore_image_path) orelse return null;
        const url = NSURL.msgSend(objc.Object, objc.sel("fileURLWithPath:"), .{path_str});

        const obj = VZMacOSInstaller.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("initWithVirtualMachine:restoreImageURL:"), .{ vm.obj, url });

        const progress = obj.msgSend(objc.Object, objc.sel("progress"), .{});

        return .{ .obj = obj, .progress = progress };
    }

    /// Start the installation (blocking until complete, with progress callback)
    pub fn install(self: *MacOSInstaller, progress_callback: ?*const fn (f64) void) AsyncResult {
        var result = std.atomic.Value(AsyncResult).init(.pending);

        const InstallContext = struct {
            result: *std.atomic.Value(AsyncResult),
        };

        const InstallBlock = objc.Block(InstallContext, .{?*anyopaque}, void);

        var block = InstallBlock.init(.{ .result = &result }, &struct {
            fn handler(ctx: *const InstallBlock.Context, err: ?*anyopaque) callconv(.c) void {
                if (err) |err_ptr| {
                    const err_obj = objc.Object{ .value = @ptrCast(@alignCast(err_ptr)) };
                    const desc = err_obj.msgSend(objc.Object, objc.sel("localizedDescription"), .{});
                    const cstr = desc.msgSend([*:0]const u8, objc.sel("UTF8String"), .{});
                    std.debug.print("\n  Installation error: {s}\n", .{cstr});
                    ctx.result.store(.failed, .release);
                } else {
                    ctx.result.store(.success, .release);
                }
            }
        }.handler);

        self.obj.msgSend(void, objc.sel("installWithCompletionHandler:"), .{&block});

        var run_loop = RunLoop.current() orelse return .failed;
        var last_progress: f64 = 0;

        while (result.load(.acquire) == .pending) {
            run_loop.runOnce();

            const current_progress = self.fractionCompleted();
            if (current_progress - last_progress >= 0.01) {
                last_progress = current_progress;
                if (progress_callback) |cb| {
                    cb(current_progress);
                }
            }
        }

        return result.load(.acquire);
    }

    /// Get installation progress (0.0 to 1.0)
    pub fn fractionCompleted(self: MacOSInstaller) f64 {
        return self.progress.msgSend(f64, objc.sel("fractionCompleted"), .{});
    }

    pub fn deinit(self: MacOSInstaller) void {
        self.obj.release();
    }
};

/// USB Mass Storage Device - for mounting ISOs as bootable USB drives
pub const USBStorage = struct {
    obj: objc.Object,

    pub fn initWithISO(path: [:0]const u8) ?USBStorage {
        const VZDiskAttachment = objc.getClass("VZDiskImageStorageDeviceAttachment") orelse return null;
        const VZUSBMassStorage = objc.getClass("VZUSBMassStorageDeviceConfiguration") orelse return null;
        const NSURL = objc.getClass("NSURL") orelse return null;

        const path_str = toNSString(path) orelse return null;
        const disk_url = NSURL.msgSend(objc.Object, objc.sel("fileURLWithPath:"), .{path_str});

        // Use raw msgSend to work around zig-objc optional return type issue
        const c = @import("objc").c;
        const MsgSendFn = *const fn (c.id, c.SEL, c.id, u8, ?*anyopaque) callconv(.c) c.id;
        const msg_send_fn: MsgSendFn = @ptrCast(&c.objc_msgSend);

        const alloc_obj = VZDiskAttachment.msgSend(objc.Object, objc.sel("alloc"), .{});
        const raw_attachment = msg_send_fn(
            alloc_obj.value,
            objc.sel("initWithURL:readOnly:error:").value,
            disk_url.value,
            1, // readOnly = YES
            null,
        );

        if (raw_attachment == null) return null;
        const attachment = objc.Object{ .value = raw_attachment.? };

        const usb_device = VZUSBMassStorage.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("initWithAttachment:"), .{attachment.value});

        return .{ .obj = usb_device };
    }

    pub fn deinit(self: *USBStorage) void {
        self.obj.release();
    }
};

pub const Storage = struct {
    obj: objc.Object,

    pub fn initDiskImage(path: [:0]const u8, read_only: bool) ?Storage {
        const VZDiskAttachment = objc.getClass("VZDiskImageStorageDeviceAttachment") orelse return null;
        const VZBlockDevice = objc.getClass("VZVirtioBlockDeviceConfiguration") orelse return null;
        const NSURL = objc.getClass("NSURL") orelse return null;

        const path_str = toNSString(path) orelse return null;
        const disk_url = NSURL.msgSend(objc.Object, objc.sel("fileURLWithPath:"), .{path_str});

        // Use raw msgSend to work around zig-objc optional return type issue
        const c = @import("objc").c;
        const MsgSendFn = *const fn (c.id, c.SEL, c.id, u8, ?*anyopaque) callconv(.c) c.id;
        const msg_send_fn: MsgSendFn = @ptrCast(&c.objc_msgSend);

        const alloc_obj = VZDiskAttachment.msgSend(objc.Object, objc.sel("alloc"), .{});
        const raw_attachment = msg_send_fn(
            alloc_obj.value,
            objc.sel("initWithURL:readOnly:error:").value,
            disk_url.value,
            if (read_only) 1 else 0,
            null,
        );

        if (raw_attachment == null) return null;
        const attachment = objc.Object{ .value = raw_attachment.? };

        const block_device = VZBlockDevice.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("initWithAttachment:"), .{attachment.value});

        return .{ .obj = block_device };
    }

    pub fn deinit(self: *Storage) void {
        self.obj.release();
    }
};

pub const SharedDirectory = struct {
    obj: objc.Object,

    pub fn init(host_path: [:0]const u8, tag: [:0]const u8, read_only: bool) ?SharedDirectory {
        const VZSharedDirectory = objc.getClass("VZSharedDirectory") orelse return null;
        const VZSingleDirectoryShare = objc.getClass("VZSingleDirectoryShare") orelse return null;
        const VZVirtioFileSystemDevice = objc.getClass("VZVirtioFileSystemDeviceConfiguration") orelse return null;
        const NSURL = objc.getClass("NSURL") orelse return null;

        const url = NSURL.msgSend(objc.Object, objc.sel("fileURLWithPath:"), .{
            toNSString(host_path) orelse return null,
        });

        const shared_dir = VZSharedDirectory.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("initWithURL:readOnly:"), .{ url, read_only });

        const dir_share = VZSingleDirectoryShare.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("initWithDirectory:"), .{shared_dir});

        const fs_device = VZVirtioFileSystemDevice.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("initWithTag:"), .{toNSString(tag) orelse return null});
        fs_device.msgSend(void, objc.sel("setShare:"), .{dir_share});

        return .{ .obj = fs_device };
    }

    pub fn deinit(self: *SharedDirectory) void {
        self.obj.release();
    }
};

pub fn isRosettaSupported() bool {
    const vz_rosetta_share = objc.getClass("VZLinuxRosettaDirectoryShare") orelse return false;
    return vz_rosetta_share.msgSend(bool, objc.sel("isSupported"), .{});
}

pub const RosettaShare = struct {
    obj: objc.Object,

    pub fn init(tag: [:0]const u8) ?RosettaShare {
        if (!isRosettaSupported()) return null;

        const VZLinuxRosettaDirectoryShare = objc.getClass("VZLinuxRosettaDirectoryShare") orelse return null;
        const VZVirtioFileSystemDevice = objc.getClass("VZVirtioFileSystemDeviceConfiguration") orelse return null;

        const rosetta_share = VZLinuxRosettaDirectoryShare.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(?objc.Object, objc.sel("initWithError:"), .{@as(?*anyopaque, null)}) orelse return null;

        const fs_device = VZVirtioFileSystemDevice.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("initWithTag:"), .{toNSString(tag) orelse return null});
        fs_device.msgSend(void, objc.sel("setShare:"), .{rosetta_share});

        return .{ .obj = fs_device };
    }

    pub fn deinit(self: RosettaShare) void {
        self.obj.release();
    }
};

pub const VirtioGraphicsDevice = struct {
    obj: objc.Object,

    pub fn init(width: u32, height: u32) ?VirtioGraphicsDevice {
        const VZVirtioGraphicsDeviceConfiguration = objc.getClass("VZVirtioGraphicsDeviceConfiguration") orelse return null;
        const VZVirtioGraphicsScanoutConfiguration = objc.getClass("VZVirtioGraphicsScanoutConfiguration") orelse return null;
        const NSArray = objc.getClass("NSArray") orelse return null;

        const scanout = VZVirtioGraphicsScanoutConfiguration.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("initWithWidthInPixels:heightInPixels:"), .{
            @as(c_long, width),
            @as(c_long, height),
        });

        const scanouts_array = NSArray.msgSend(objc.Object, objc.sel("arrayWithObject:"), .{scanout});

        const graphics_device = VZVirtioGraphicsDeviceConfiguration.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});
        graphics_device.msgSend(void, objc.sel("setScanouts:"), .{scanouts_array});

        return .{ .obj = graphics_device };
    }

    pub fn deinit(self: VirtioGraphicsDevice) void {
        self.obj.release();
    }
};

pub const VirtioSocket = struct {
    obj: objc.Object,

    pub fn init() ?VirtioSocket {
        const VZVirtioSocketDevice = objc.getClass("VZVirtioSocketDeviceConfiguration") orelse return null;

        const socket_device = VZVirtioSocketDevice.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});

        return .{ .obj = socket_device };
    }

    pub fn deinit(self: VirtioSocket) void {
        self.obj.release();
    }
};

pub const VirtioSound = struct {
    obj: objc.Object,

    pub fn init() ?VirtioSound {
        const VZVirtioSoundDevice = objc.getClass("VZVirtioSoundDeviceConfiguration") orelse return null;
        const VZVirtioSoundDeviceInputStreamConfiguration = objc.getClass("VZVirtioSoundDeviceInputStreamConfiguration") orelse return null;
        const VZVirtioSoundDeviceOutputStreamConfiguration = objc.getClass("VZVirtioSoundDeviceOutputStreamConfiguration") orelse return null;
        const NSArray = objc.getClass("NSArray") orelse return null;

        const sound_device = VZVirtioSoundDevice.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});

        const input_stream = VZVirtioSoundDeviceInputStreamConfiguration.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});

        const output_stream = VZVirtioSoundDeviceOutputStreamConfiguration.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});

        const streams_array = NSArray.msgSend(objc.Object, objc.sel("arrayWithObjects:count:"), .{
            @as([*]const objc.Object, &[_]objc.Object{ input_stream, output_stream }),
            @as(c_ulong, 2),
        });

        sound_device.msgSend(void, objc.sel("setStreams:"), .{streams_array});

        return .{ .obj = sound_device };
    }

    pub fn deinit(self: VirtioSound) void {
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

    pub fn deinit(self: Network) void {
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

pub const StartResult = enum(u8) {
    success,
    failed,
    pending,
};

const CompletionContext = struct {
    result: *std.atomic.Value(StartResult),
};

const StartBlock = objc.Block(CompletionContext, .{?*anyopaque}, void);

fn completionHandler(ctx: *const StartBlock.Context, err: ?*anyopaque) callconv(.c) void {
    if (err != null) {
        ctx.result.store(.failed, .release);
    } else {
        ctx.result.store(.success, .release);
    }
}

pub const VirtualMachine = struct {
    obj: objc.Object,

    pub fn init(config: Configuration) ?VirtualMachine {
        const VZVirtualMachine = objc.getClass("VZVirtualMachine") orelse return null;

        const obj = VZVirtualMachine.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("initWithConfiguration:"), .{config.obj});

        return .{ .obj = obj };
    }

    pub fn deinit(self: VirtualMachine) void {
        self.obj.release();
    }

    pub fn state(self: *VirtualMachine) VMState {
        const raw_state = self.obj.msgSend(c_long, objc.sel("state"), .{});
        return @enumFromInt(raw_state);
    }

    pub fn canStart(self: *VirtualMachine) bool {
        return self.obj.msgSend(bool, objc.sel("canStart"), .{});
    }

    pub fn canStop(self: *VirtualMachine) bool {
        return self.obj.msgSend(bool, objc.sel("canStop"), .{});
    }

    pub fn canRequestStop(self: *VirtualMachine) bool {
        return self.obj.msgSend(bool, objc.sel("canRequestStop"), .{});
    }

    pub fn start(self: *VirtualMachine) StartResult {
        var result = std.atomic.Value(StartResult).init(.pending);

        var block = StartBlock.init(.{ .result = &result }, &completionHandler);
        self.obj.msgSend(void, objc.sel("startWithCompletionHandler:"), .{&block});

        var run_loop = RunLoop.current() orelse return .failed;
        while (result.load(.acquire) == .pending) {
            run_loop.runOnce();
        }

        return result.load(.acquire);
    }

    pub fn requestStop(self: *VirtualMachine) bool {
        return self.obj.msgSend(bool, objc.sel("requestStopWithError:"), .{@as(?*anyopaque, null)});
    }

    pub fn stop(self: *VirtualMachine) StartResult {
        var result = std.atomic.Value(StartResult).init(.pending);

        var block = StartBlock.init(.{ .result = &result }, &completionHandler);
        self.obj.msgSend(void, objc.sel("stopWithCompletionHandler:"), .{&block});

        var run_loop = RunLoop.current() orelse return .failed;
        while (result.load(.acquire) == .pending) {
            run_loop.runOnce();
        }

        return result.load(.acquire);
    }
};

fn toNSString(str: [:0]const u8) ?objc.Object {
    const ns_string = objc.getClass("NSString") orelse return null;
    return ns_string.msgSend(objc.Object, objc.sel("stringWithUTF8String:"), .{str.ptr});
}

test "isSupported" {
    _ = isSupported();
}

test "isMacOSVMSupported" {
    _ = isMacOSVMSupported();
}

test "isRosettaSupported" {
    _ = isRosettaSupported();
}
