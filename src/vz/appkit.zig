const std = @import("std");
const objc = @import("objc");

pub const NSApplication = struct {
    obj: objc.Object,

    pub fn sharedApplication() ?NSApplication {
        const NSApp = objc.getClass("NSApplication") orelse return null;
        const obj = NSApp.msgSend(objc.Object, objc.sel("sharedApplication"), .{});
        return .{ .obj = obj };
    }

    pub fn setActivationPolicy(self: *NSApplication, policy: c_long) bool {
        return self.obj.msgSend(bool, objc.sel("setActivationPolicy:"), .{policy});
    }

    pub fn activateIgnoringOtherApps(self: *NSApplication, flag: bool) void {
        self.obj.msgSend(void, objc.sel("activateIgnoringOtherApps:"), .{flag});
    }

    pub fn run(self: *NSApplication) void {
        self.obj.msgSend(void, objc.sel("run"), .{});
    }

    pub fn runOnce(self: *NSApplication) void {
        const c = @import("objc").c;
        const NSDate = objc.getClass("NSDate") orelse return;
        const distant_past = NSDate.msgSend(objc.Object, objc.sel("distantPast"), .{});

        const MsgSendFn = *const fn (c.id, c.SEL, c_ulonglong, c.id, c.id, u8) callconv(.c) c.id;
        const msg_send_fn: MsgSendFn = @ptrCast(&c.objc_msgSend);

        const NSDefaultRunLoopMode = objc.getClass("NSString").?.msgSend(objc.Object, objc.sel("stringWithUTF8String:"), .{@as([*:0]const u8, "kCFRunLoopDefaultMode")});

        const event = msg_send_fn(
            self.obj.value,
            objc.sel("nextEventMatchingMask:untilDate:inMode:dequeue:").value,
            0xFFFFFFFFFFFFFFFF,
            distant_past.value,
            NSDefaultRunLoopMode.value,
            1,
        );

        if (event) |e| {
            self.obj.msgSend(void, objc.sel("sendEvent:"), .{objc.Object{ .value = e }});
        }
    }

    pub fn stop(self: *NSApplication, sender: ?objc.Object) void {
        const sender_val = if (sender) |s| s.value else null;
        self.obj.msgSend(void, objc.sel("stop:"), .{sender_val});
    }
};

pub const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,
};

pub const NSPoint = extern struct {
    x: f64,
    y: f64,
};

pub const NSSize = extern struct {
    width: f64,
    height: f64,
};

pub const NSWindow = struct {
    obj: objc.Object,

    pub fn initWithContentRect(rect: NSRect, style_mask: c_ulong, backing: c_ulong, defer_flag: bool) ?NSWindow {
        const NSWindowClass = objc.getClass("NSWindow") orelse return null;

        const c = @import("objc").c;
        const MsgSendFn = *const fn (c.id, c.SEL, NSRect, c_ulong, c_ulong, u8) callconv(.c) c.id;
        const msg_send_fn: MsgSendFn = @ptrCast(&c.objc_msgSend);

        const allocated = NSWindowClass.msgSend(objc.Object, objc.sel("alloc"), .{});
        const raw_obj = msg_send_fn(
            allocated.value,
            objc.sel("initWithContentRect:styleMask:backing:defer:").value,
            rect,
            style_mask,
            backing,
            if (defer_flag) 1 else 0,
        );

        if (raw_obj == null) return null;
        return .{ .obj = objc.Object{ .value = raw_obj.? } };
    }

    pub fn setTitle(self: *NSWindow, title: [:0]const u8) void {
        const NSString = objc.getClass("NSString") orelse return;
        const title_str = NSString.msgSend(objc.Object, objc.sel("stringWithUTF8String:"), .{title.ptr});
        self.obj.msgSend(void, objc.sel("setTitle:"), .{title_str});
    }

    pub fn makeKeyAndOrderFront(self: *NSWindow, sender: ?objc.Object) void {
        const sender_val = if (sender) |s| s.value else null;
        self.obj.msgSend(void, objc.sel("makeKeyAndOrderFront:"), .{sender_val});
    }

    pub fn setContentView(self: *NSWindow, view: objc.Object) void {
        self.obj.msgSend(void, objc.sel("setContentView:"), .{view});
    }

    pub fn deinit(self: *NSWindow) void {
        self.obj.release();
    }
};

pub const VirtualMachineView = struct {
    obj: objc.Object,

    pub fn init() ?VirtualMachineView {
        const VZVirtualMachineView = objc.getClass("VZVirtualMachineView") orelse return null;

        const obj = VZVirtualMachineView.msgSend(objc.Object, objc.sel("alloc"), .{})
            .msgSend(objc.Object, objc.sel("init"), .{});

        return .{ .obj = obj };
    }

    pub fn setVirtualMachine(self: *VirtualMachineView, vm: objc.Object) void {
        self.obj.msgSend(void, objc.sel("setVirtualMachine:"), .{vm});
    }

    pub fn deinit(self: *VirtualMachineView) void {
        self.obj.release();
    }
};
