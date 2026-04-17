const fuzz = @This();

// `$ zig build test -Dllvm --fuzz`
test fuzz { //
    zig_fuzz_init();
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            zig_fuzz_test(input.ptr, input.len);
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}

const DataProvider = struct {
    data: []const u8,
    // Returns a number in the range [min, max] by consuming bytes from the
    // input data. The value might not be uniformly distributed in the given
    // range. If there's no input data left, always returns |min|. |min| must
    // be less than or equal to |max|.
    pub fn ConsumeIntegralInRange(fdp: *DataProvider, T: type, min: T, max: T) T {
        comptime assert(@typeInfo(T) == .int and @sizeOf(T) <= @sizeOf(u64)); // "Unsupported integral type

        // Use the biggest type possible to hold the range and the result.
        const range = @as(u64, max) - min;
        var result: u64 = 0;
        var offset: usize = 0;
        const CHAR_BIT = 8;
        while (offset < @sizeOf(T) * CHAR_BIT and
            (range >> @intCast(offset)) > 0 and
            fdp.data.len != 0)
        {
            // Pull bytes off the end of the seed data. Experimentally, this seems to
            // allow the fuzzer to more easily explore the input space. This makes
            // sense, since it works by modifying inputs that caused new code to run,
            // and this data is often used to encode length of data read by
            // |ConsumeBytes|. Separating out read lengths makes it easier modify the
            // contents of the data that is actually read.
            fdp.data.len -= 1;
            result = (result << CHAR_BIT) | fdp.data.ptr[fdp.data.len];
            offset += CHAR_BIT;
        }

        // Avoid division by 0, in case |range + 1| results in overflow.
        if (range != std.math.maxInt(u64))
            result = result % (range + 1);

        return @intCast(min + result);
    }

    pub fn ConsumeVecInRange(
        fdp: *DataProvider,
        allocator: mem.Allocator,
        length: usize,
        min_value: u32,
        max_value: u32,
    ) !std.ArrayList(u32) {
        var result = std.ArrayList(u32).empty;
        try result.resize(allocator, length);
        for (result.items) |*it| {
            it.* = fdp.ConsumeIntegralInRange(u32, min_value, max_value);
        }
        return result;
    }
};

var gpa_buf: ?[]u8 = null;
const gpa_buf_size = 100 * 1024 * 1024; // 100 Mb
var gpa: mem.Allocator = undefined;
var gpa_state: std.heap.DebugAllocator(.{}) = undefined;
fn oom() noreturn {
    @panic("OOM");
}

export fn zig_fuzz_init() void {
    // init alloc_buf
    assert(gpa_buf == null);
    gpa_state = .{};
    gpa = gpa_state.allocator();
    gpa_buf = gpa.alloc(u8, gpa_buf_size) catch oom();
}

///
/// A bitmap may contain up to 2**32 elements. Later this function will
/// output the content to an array where each element uses 32 bits of
/// storage. That would use 16 GB. Thus this function is bound to run out of
/// memory.
///
/// Even without the full serialization to a 32-bit array, a bitmap may still
/// use over 512 MB in the normal course of operation: that is to be expected
/// since it can represent all sets of integers in [0,2**32]. This function
/// may hold several bitmaps in memory at once, so it can require gigabytes
/// of memory (without bugs). Hence, unless it has a generous memory
/// capacity, this function will run out of memory almost certainly.
///
/// For sanity, we may limit the range to, say, 10,000,000 which will use 38
/// MB or so. With such a limited range, if we run out of memory, then we can
/// almost certain that it has to do with a genuine bug.
///
export fn zig_fuzz_test(dataptr: [*]const u8, size: usize) void {
    zig_fuzz_test1(dataptr[0..size]) catch return;
}

fn zig_fuzz_test1(data: []const u8) !void {
    _ = bitmap32(data);
    const range_start: u32 = 0;
    const range_end: u32 = 10_000_000;

    //
    // We are not solely dependent on the range [range_start, range_end) because
    // ConsumeVecInRange below produce integers in a small range starting at 0.
    //

    var fdp: DataProvider = .{ .data = data };
    //
    // The next line was ConsumeVecInRange(fdp, 500, 0, 1000) but it would pick
    // 500 values at random from 0, 1000, making almost certain that all of the
    // values are picked. It seems more useful to pick 500 values in the range
    // 0,1000.
    //
    var fba = std.heap.FixedBufferAllocator.init(gpa_buf.?);
    const alloc = fba.allocator();
    const bitmap_data_a = try fdp.ConsumeVecInRange(alloc, 500, 0, 1000);
    // std.debug.print("bitmap_data_a {any}\n", .{bitmap_data_a});
    var a: Bitmap = .{};
    try a.add_many(alloc, bitmap_data_a.items);
    if (true) unreachable; // TODO
    _ = try a.run_optimize(alloc);

    const bitmap_data_b = try fdp.ConsumeVecInRange(alloc, 500, 0, 1000);
    // std.debug.print("bitmap_data_b {any}\n", .{bitmap_data_b});
    var b: Bitmap = .{};
    try b.add_many(alloc, bitmap_data_b.items);
    _ = try b.run_optimize(alloc);
    try b.add(alloc, fdp.ConsumeIntegralInRange(u32, range_start, range_end));
    _ = try b.add_checked(alloc, fdp.ConsumeIntegralInRange(u32, range_start, range_end));
    const r0 = fdp.ConsumeIntegralInRange(u32, range_start, range_end);
    const r1 = fdp.ConsumeIntegralInRange(u32, range_start, range_end);
    const rmin = @min(r0, r1);
    const rmax = @max(r0, r1);
    if (rmin < rmax) try b.add_range(alloc, rmin, rmax);
    // std.log.debug("{} data_b {any} {f}\n", .{ size, bitmap_data_b.items, b });
}

fn bitmap32(data: []const u8) u8 {
    if (true) unreachable; // TODO
    // We test that deserialization never fails.
    var r = std.Io.Reader.fixed(data);
    var bitmap = zroaring.Bitmap.portable_deserialize_safe(gpa, &r) catch return 0;
    defer bitmap.deinit(gpa);
    // The bitmap may not be usable if it does not follow the specification.
    // We can validate the bitmap we recovered to make sure it is proper.
    var reason_failure: ?[]const u8 = undefined;
    if (bitmap.internal_validate(@ptrCast(&reason_failure))) {
        // the bitmap is ok!
        var cardinality = bitmap.get_cardinality();
        for (100..1000) |ii| {
            const i: u32 = @intCast(ii);
            if (!bitmap.contains(i)) {
                cardinality += 1;
                bitmap.add(gpa, i) catch return 0;
            }
        }
        if (cardinality != bitmap.get_cardinality()) {
            std.debug.print("bug\n", .{});
            std.process.exit(1);
        }
    }
    return 0;
}

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const zroaring = @import("root.zig");
const Bitmap = zroaring.Bitmap;
