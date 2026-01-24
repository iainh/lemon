const objc = @import("objc");

pub const RunLoop = struct {
    obj: objc.Object,

    pub fn current() ?RunLoop {
        const NSRunLoop = objc.getClass("NSRunLoop") orelse return null;
        const obj = NSRunLoop.msgSend(objc.Object, objc.sel("currentRunLoop"), .{});
        return .{ .obj = obj };
    }

    pub fn main() ?RunLoop {
        const NSRunLoop = objc.getClass("NSRunLoop") orelse return null;
        const obj = NSRunLoop.msgSend(objc.Object, objc.sel("mainRunLoop"), .{});
        return .{ .obj = obj };
    }

    pub fn runUntilDate(self: *RunLoop, seconds: f64) void {
        const NSDate = objc.getClass("NSDate") orelse return;
        const date = NSDate.msgSend(objc.Object, objc.sel("dateWithTimeIntervalSinceNow:"), .{seconds});
        self.obj.msgSend(void, objc.sel("runUntilDate:"), .{date});
    }

    pub fn runOnce(self: *RunLoop) void {
        self.runUntilDate(0.1);
    }
};

pub const DispatchQueue = struct {
    obj: objc.Object,

    pub fn main() ?DispatchQueue {
        const queue = dispatch_get_main_queue();
        if (queue) |q| {
            return .{ .obj = .{ .value = q } };
        }
        return null;
    }

    pub fn async_(self: *DispatchQueue, block: anytype) void {
        dispatch_async(self.obj.value, block);
    }

    extern "c" fn dispatch_get_main_queue() callconv(.c) ?*anyopaque;
    extern "c" fn dispatch_async(queue: ?*anyopaque, block: anytype) callconv(.c) void;
};
