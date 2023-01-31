const std = @import("std");
const testing = std.testing;
const trait = std.meta.trait;
const builtin = @import("builtin");

/// Represent a value returned by async task in the future.
pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        done: std.Thread.ResetEvent,
        data: ?T,

        pub fn init(allocator: std.mem.Allocator) !*Self {
            var self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .done = .{},
                .data = null,
            };
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (!self.done.isSet()) {
                @panic("future isn't done yet!");
            }
            if (self.data) |data| {
                // Destroy data when possible
                // Only detect one layer of optional/error-union
                switch (@typeInfo(T)) {
                    .Optional => |info| {
                        if (comptime trait.isSingleItemPtr(info.child) and
                            trait.hasFn("deinit")(@typeInfo(info.child).Pointer.child))
                        {
                            if (data) |d| d.deinit();
                        } else if (comptime trait.hasFn("deinit")(info.child)) {
                            if (data) |d| d.deinit();
                        }
                    },
                    .ErrorUnion => |info| {
                        if (comptime trait.isSingleItemPtr(info.payload) and
                            trait.hasFn("deinit")(@typeInfo(info.payload).Pointer.child))
                        {
                            if (data) |d| d.deinit() else |_| {}
                        } else if (comptime trait.hasFn("deinit")(info.payload)) {
                            if (data) |d| d.deinit() else |_| {}
                        }
                    },
                    else => {
                        if (comptime trait.hasFn("deinit")(T)) {
                            data.deinit();
                        }
                    },
                }
            }
            self.allocator.destroy(self);
        }

        /// Wait until data is granted
        pub fn wait(self: *Self) T {
            self.done.wait();
            std.debug.assert(self.data != null);
            return self.data.?;
        }

        /// Wait until data is granted or timeout happens
        pub fn timedWait(self: *Self, time_ns: u64) ?T {
            self.done.timedWait(time_ns) catch {};
            return self.data;
        }

        /// Grant data and send signal to waiting threads
        pub fn grant(self: *Self, data: T) void {
            self.data = data;
            self.done.set();
        }
    };
}

/// Async task runs in another thread
pub fn Task(comptime fun: anytype) type {
    return struct {
        pub const FunType = @TypeOf(fun);
        pub const ArgsType = std.meta.ArgsTuple(FunType);
        pub const ReturnType = @typeInfo(FunType).Fn.return_type.?;
        pub const FutureType = Future(ReturnType);

        /// Internal thread function, run user's function and
        /// grant result to future.
        fn task(future: *FutureType, args: ArgsType) void {
            const ret = @call(.auto, fun, args);
            future.grant(ret);
        }

        /// Create task thread and detach from it
        pub fn launch(allocator: std.mem.Allocator, args: ArgsType) !*FutureType {
            var future = try FutureType.init(allocator);
            errdefer future.deinit();
            var thread = try std.Thread.spawn(.{}, task, .{ future, args });
            thread.detach();
            return future;
        }
    };
}

test "Async Task" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const channel = @import("channel.zig");
    const Channel = channel.Channel;
    const S = struct {
        const R = struct {
            allocator: std.mem.Allocator,
            v: u32,

            pub fn deinit(self: *@This()) void {
                std.debug.print("\ndeinit R, v is {d}", .{self.v});
                self.allocator.destroy(self);
            }
        };

        fn div(allocator: std.mem.Allocator, a: u32, b: u32) !*R {
            if (b == 0) return error.DivisionByZero;
            var r = try allocator.create(R);
            r.* = .{
                .allocator = allocator,
                .v = @divTrunc(a, b),
            };
            return r;
        }

        fn return_nothing() void {}

        fn long_work(ch: *Channel(u32), a: u32, b: u32) u32 {
            std.time.sleep(std.time.ns_per_s);
            ch.push(std.math.pow(u32, a, 1)) catch unreachable;
            std.time.sleep(std.time.ns_per_ms * 10);
            ch.push(std.math.pow(u32, a, 2)) catch unreachable;
            std.time.sleep(std.time.ns_per_ms * 10);
            ch.push(std.math.pow(u32, a, 3)) catch unreachable;
            return a + b;
        }

        fn add(f1: *Future(?u128), f2: *Future(?u128)) ?u128 {
            const a = f1.wait().?;
            const b = f2.wait().?;
            return a + b;
        }
    };

    {
        const TestTask = Task(S.div);
        var future = TestTask.launch(std.testing.allocator, .{ std.testing.allocator, 1, 0 }) catch unreachable;
        defer future.deinit();
        try testing.expectError(error.DivisionByZero, future.wait());
        try testing.expectError(error.DivisionByZero, future.timedWait(10).?);
    }

    {
        const TestTask = Task(S.div);
        var future = TestTask.launch(std.testing.allocator, .{ std.testing.allocator, 1, 1 }) catch unreachable;
        defer future.deinit();
        const ret = future.wait();
        try testing.expectEqual(@as(u32, 1), if (ret) |r| r.v else |_| unreachable);
    }

    {
        const TestTask = Task(S.return_nothing);
        var future = TestTask.launch(std.testing.allocator, .{}) catch unreachable;
        future.wait();
        defer future.deinit();
    }

    {
        var ch = try channel.Channel(u32).init(std.testing.allocator);
        defer ch.deinit();

        const TestTask = Task(S.long_work);
        var future = TestTask.launch(std.testing.allocator, .{ ch, 2, 1 }) catch unreachable;
        defer future.deinit();

        try testing.expectEqual(@as(?u32, null), future.timedWait(1));
        try testing.expectEqual(@as(?u32, null), future.timedWait(1));
        try testing.expectEqual(@as(?u32, null), future.timedWait(1));
        try testing.expectEqual(@as(?u32, null), future.timedWait(1));
        try testing.expectEqual(@as(?u32, null), future.timedWait(1));
        try testing.expectEqual(@as(?u32, null), future.timedWait(1));
        try testing.expectEqual(@as(?u32, null), future.timedWait(1));
        try testing.expectEqual(@as(?u32, null), future.timedWait(1));
        try testing.expectEqual(@as(?u32, null), ch.pop());
        try testing.expectEqual(@as(u32, 3), future.wait());

        var result = ch.popn(3).?;
        try testing.expectEqual(result.elements.items.len, 3);
        try testing.expectEqual(@as(u32, 2), result.elements.items[0]);
        try testing.expectEqual(@as(u32, 4), result.elements.items[1]);
        try testing.expectEqual(@as(u32, 8), result.elements.items[2]);
        result.deinit();
    }

    {
        const TestTask = Task(S.add);
        var fs: [100]*TestTask.FutureType = undefined;
        fs[0] = try TestTask.FutureType.init(std.testing.allocator);
        fs[1] = try TestTask.FutureType.init(std.testing.allocator);
        fs[0].grant(0);
        fs[1].grant(1);

        // compute 100th fibonacci number
        var i: u32 = 2;
        while (i < 100) : (i += 1) {
            fs[i] = try TestTask.launch(std.testing.allocator, .{ fs[i - 2], fs[i - 1] });
        }
        try testing.expectEqual(@as(u128, 218922995834555169026), fs[99].wait().?);
        for (fs) |f| f.deinit();
    }
}
