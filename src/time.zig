const std = @import("std");
const convert = @import("convert.zig");

const LocalBuffer = @import("localbuffer.zig").LocalBuffer;
const print = std.debug.print;
const assert = std.debug.assert;
const RandGen = std.rand.DefaultPrng;
const expect = std.testing.expect;

// :::::::::::::::::: For easy scope-based benchmarking. thread-safe in up to 32 threads.
// :::::: Time :::::: And, for waiting. We all love waiting.
// ::::::::::::::::::

// Usage:
//  // at program or test initialization (and pay attention to defer order w/ respect to allocator deinit)
//  try utils.time.initScopeTimers(1)
//  defer shutdownScopeTimers(true);
//
// // indiviual timer
// {
//      const t = ScopeTimer.start(callsiteID("Some Scope Name", 0));
//      defer t.stop();
//      // .. code you want to benchmark
// }
//
// Names are limited to 63 characters. the number passed into getScopeTimerID() represents which thread from which the
// (inline) function is called. if your program is singled threaded, just 0 every time is fine. If not, be sure
// to call initScopeTimers(n) where n = the number of threads using scope timers.
//
// At the end of the program (or whenever you're interested in the times), call printAllScopeTimers().

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// --------------------------------------------------------------------------------------------------------------- stuff
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

const TimeError = error {
    Max32ThreadsForScopeTimers,
};

pub inline fn waitFor(timer: *std.time.Timer, nanoseconds: u64) u64 {
    var time_elapsed: u64 = timer.read();
    while (time_elapsed < nanoseconds) {
        std.time.sleep(10_000);
        time_elapsed = timer.read();
    }
    return time_elapsed;
}

// must be called once before using any scope timers, in the main thread.
pub fn initScopeTimers(thread_ct: usize, allocator: std.mem.Allocator) !void {
    if (thread_ct > 32) {
        return TimeError.Max32ThreadsForScopeTimers;
    }
    if (thread_ct > 0) {
        timer_lists = timer_list_buf[0..thread_ct];
        for (timer_lists) |*timer_list| {
            timer_list.* = try std.ArrayList(InternalTimer).initCapacity(allocator, 32);
        }
    }
}

pub fn shutdownScopeTimers(print_timers: bool) void {
    if (print_timers) {
        printAllScopeTimers(false);
    }
    for (timer_lists) |*timer_list| {
        timer_list.clearAndFree();
    }
    timer_lists = undefined;
    restart_ct = @addWithOverflow(restart_ct, 1)[0];
}

pub inline fn callsiteID(comptime name: []const u8, comptime thread_id: comptime_int) ?ScopeTimerID {
    // due to callsiteID() being inline, this var 'timer_id' is local to the call site, 
    // like a static int declared in a macro in C
    const LocalID = struct { var timer_id: i16 = -1; var restart_ct: u16 = 0; };
    // if the id hasn't been initialized, there is no timer for this callsite.
    // (and, when the system is restarted, every callsite will need a new ID because the old ID represents a freed timer)
    if (LocalID.timer_id == -1 or LocalID.restart_ct != restart_ct) {
        LocalID.timer_id = addTimer(thread_id, name) catch return null;
        LocalID.restart_ct = restart_ct;
    }
    // the thread id and timer id will be used to index to the timer at ScopeTimer::stop()
    return ScopeTimerID{ .thread_id=thread_id, .timer_id=@intCast(LocalID.timer_id) };
}

pub fn printAllScopeTimers(print_ids: bool) void {
    print("\n", .{});
    var thread_id: u32 = 0;
    for (timer_lists) |timer_list| {
        var timer_id: u32 = 0;
        for (timer_list.items) |timer| {
            const report = getScopeTimerReportInternal(&timer);
            print("--- scope timer |{s}| ---\n", .{timer.name});
            print("avg: {d:0.5} ms // max: {d:0.4} ms // min: {d:0.4} ms\n", 
                .{report.avg_time, report.max_time, report.min_time}
            );
            if (print_ids) {
                print("thread id: {}, timer id: {}\n", .{thread_id, timer_id});
            }
            timer_id += 1;
        }
        thread_id += 1;
    }
}

inline fn getScopeTimerReportInternal(timer: *const InternalTimer) ScopeTimerReport {
    const total_time_f: f64 = @floatFromInt(timer.total_time);
    const ticks_f: f64 = @floatFromInt(timer.log_ct);
    return ScopeTimerReport{
        .avg_time = convert.nano100ToMilli(total_time_f / ticks_f),
        .max_time = convert.nano100ToMilli(@as(f64, @floatFromInt(timer.max_time))),
        .min_time = convert.nano100ToMilli(@as(f64, @floatFromInt(timer.min_time))),
    };
}

pub inline fn getScopeTimerReport(id: ScopeTimerID) ScopeTimerReport {
    const timer: *const InternalTimer = &timer_lists[id.thread_id].items[id.timer_id];
    return getScopeTimerReportInternal(timer);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// --------------------------------------------------------------------------------------------------------------- types
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

pub const ScopeTimer = struct {
    id: ?ScopeTimerID,
    start_time: u64,

    pub inline fn start(in_id: ?ScopeTimerID) ScopeTimer {
        const start_inst = std.time.Instant.now() catch std.time.Instant{.timestamp=0};
        return ScopeTimer{.id=in_id, .start_time=start_inst.timestamp};
    }

    pub fn stop(self: *const ScopeTimer) void {
        if (self.id == null) return;
        const end_inst = std.time.Instant.now() catch std.time.Instant{.timestamp=self.start_time};
        logEndTime(self.id.?, end_inst.timestamp - self.start_time);
    }
};

pub const ScopeTimerID = struct {
    thread_id: u32 = 0,
    timer_id: u32 = 0,
};

pub const ScopeTimerReport = struct {
    avg_time: f64,
    max_time: f64,
    min_time: f64,
};

const InternalTimer = struct {
    name: [64]u8 = undefined,
    total_time: u64 = 0, // in nanoseconds
    max_time: u64 = 0,
    min_time: u64 = std.math.maxInt(u64),
    log_ct: u64 = 0,
};

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// ---------------------------------------------------------------------------------------------------------------- data
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

var timer_list_buf: [32]std.ArrayList(InternalTimer) = undefined;
var timer_lists: []std.ArrayList(InternalTimer) = undefined;
var restart_ct: u16 = 0;

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// ------------------------------------------------------------------------------------------------------------- private
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

fn addTimer(comptime thread_id: comptime_int, comptime name: []const u8) !i16 {
    var list: *std.ArrayList(InternalTimer) = &timer_lists[thread_id];
    var timer: *InternalTimer = try list.addOne();
    timer.* = InternalTimer{};
    const min_len: usize = @min(name.len, 63);
    @memcpy(timer.name[0..min_len], name[0..min_len]);
    timer.name[min_len + 1] = '\x00';
    return @intCast(list.items.len - 1);
}

inline fn logEndTime(id: ScopeTimerID, time_ns: u64) void {
    var timer = &timer_lists[id.thread_id].items[id.timer_id];

    timer.total_time += time_ns;
    timer.log_ct += 1;

    if (time_ns > timer.max_time) {
        timer.max_time = time_ns;
    }
    if (time_ns < timer.min_time) {
        timer.min_time = time_ns;
    }
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// --------------------------------------------------------------------------------------------------------------- tests
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// fn fibonacci(x: u64) u64 {
//     if (x == 0) {
//         return 0;
//     }

//     var a: u64 = 0;
//     var b: u64 = 1;
//     var c: u64 = undefined;
//     for (2..x+1) |i| {
//         _ = i;
//         c = a + b;
//         a = b;
//         b = c;
//     }

//     return b;
// }

// fn doStuff() !void {
//     var rand = RandGen.init(0);

//     var d = ScopeTimer.start(callsiteID("d", 1)); defer d.stop();
//     var e = ScopeTimer.start(callsiteID("e", 1)); defer e.stop();
//     for (0..100) |i| {
//         _ = i;
//         var random_number = @mod(rand.random().int(u64), 64);
//         var fib = fibonacci(random_number);
//         _ = fib;
//     }
// }

// // this is more of a basic no-crash test with a little validation; prints can be looked over to make sure they
// // make sense
// // pub fn timerTest() !void {
// test "multi scope test" {
//     var rand = RandGen.init(2);
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//     try initScopeTimers(2, allocator);
//     defer shutdownScopeTimers(true);
//     print("\n", .{});

//     for (0..2) |j| {
//         _ = j;
//         var a = ScopeTimer.start(callsiteID("a", 0)); defer a.stop();
//         var b = ScopeTimer.start(callsiteID("b", 0)); defer b.stop();
//         var c = ScopeTimer.start(callsiteID("c", 0)); defer c.stop();
//         for (0..100) |i| {
//             _ = i;
//             var random_number = @mod(rand.random().int(u64), 64);
//             var fib = fibonacci(random_number);
//             _ = fib;
//         }
//         try doStuff();
//     }

//     // doStuff() timers start later and stop sooner, so their time should be less.
//     // try expect(timers.items[3].total_time < timers.items[0].total_time);
//     // try expect(timers.items[3].total_time < timers.items[1].total_time);
//     // try expect(timers.items[3].total_time < timers.items[2].total_time);
//     // try expect(timers.items[4].total_time < timers.items[0].total_time);
//     // try expect(timers.items[4].total_time < timers.items[1].total_time);
//     // try expect(timers.items[4].total_time < timers.items[2].total_time);
//     // try expect(timers.items[3].total_time > 0);
//     // try expect(timers.items[4].total_time > 0);

// }
