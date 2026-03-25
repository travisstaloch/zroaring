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

var fuzz_alloc_buf: ?[]u8 = null;
var gpa: mem.Allocator = undefined;
const fuzz_alloc_buf_size = 100 * 1024 * 1024; // 100 Mb

export fn zig_fuzz_init() void {
    var x = std.heap.GeneralPurposeAllocator(.{}){};
    gpa = x.allocator();
    assert(fuzz_alloc_buf == null);
    fuzz_alloc_buf = gpa.alloc(u8, fuzz_alloc_buf_size) catch @panic("OOM");
}

const FuzzedDataProvider = struct {
    data_ptr_: [*]const u8,
    remaining_bytes_: usize,
    // Returns a number in the range [min, max] by consuming bytes from the
    // input data. The value might not be uniformly distributed in the given
    // range. If there's no input data left, always returns |min|. |min| must
    // be less than or equal to |max|.
    // template <typename T>
    // T FuzzedDataProvider::ConsumeIntegralInRange(T min, T max) {
    pub fn ConsumeIntegralInRange(fdp: *FuzzedDataProvider, T: type, min: T, max: T) T {
        comptime assert(@typeInfo(T) == .int and @sizeOf(T) <= @sizeOf(u64)); // "Unsupported integral type

        if (min > max) std.process.exit(1);

        // Use the biggest type possible to hold the range and the result.
        const range = @as(u64, max) - min;
        var result: u64 = 0;
        var offset: usize = 0;
        const CHAR_BIT = 8;
        while (offset < @sizeOf(T) * CHAR_BIT and (range >> @intCast(offset)) > 0 and
            fdp.remaining_bytes_ != 0)
        {
            // Pull bytes off the end of the seed data. Experimentally, this seems to
            // allow the fuzzer to more easily explore the input space. This makes
            // sense, since it works by modifying inputs that caused new code to run,
            // and this data is often used to encode length of data read by
            // |ConsumeBytes|. Separating out read lengths makes it easier modify the
            // contents of the data that is actually read.
            fdp.remaining_bytes_ -= 1;
            result = (result << CHAR_BIT) | fdp.data_ptr_[fdp.remaining_bytes_];
            offset += CHAR_BIT;
        }

        // Avoid division by 0, in case |range + 1| results in overflow.
        if (range != std.math.maxInt(u64))
            result = result % (range + 1);

        return @intCast(min + result);
    }

    pub fn ConsumeVecInRange(fdp: *FuzzedDataProvider, allocator: mem.Allocator, length: usize, min_value: u32, max_value: u32) !std.ArrayList(u32) {
        var result: std.ArrayList(u32) = .{};
        try result.resize(allocator, length);
        for (result.items) |*it| {
            it.* = fdp.ConsumeIntegralInRange(u32, min_value, max_value);
        }
        return result;
    }
};

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
export fn zig_fuzz_test(data: [*]const u8, size: usize) void {
    const range_start: u32 = 0;
    const range_end: u32 = 10_000_000;

    //
    // We are not solely dependent on the range [range_start, range_end) because
    // ConsumeVecInRange below produce integers in a small range starting at 0.
    //

    var fdp: FuzzedDataProvider = .{ .data_ptr_ = data, .remaining_bytes_ = size };
    //
    // The next line was ConsumeVecInRange(fdp, 500, 0, 1000) but it would pick
    // 500 values at random from 0, 1000, making almost certain that all of the
    // values are picked. It seems more useful to pick 500 values in the range
    // 0,1000.
    //
    var fba = std.heap.FixedBufferAllocator.init(fuzz_alloc_buf.?);
    const alloc = fba.allocator();
    // const bitmap_data_a = fdp.ConsumeVecInRange(alloc, 500, 0, 1000) catch @panic("OOM");
    const bitmap_data_b = fdp.ConsumeVecInRange(alloc, 500, 0, 1000) catch @panic("OOM");
    var b: Bitmap = .{};
    b.add_many(alloc, bitmap_data_b.items) catch @panic("OOM"); // autofix
    _ = b.run_optimize(alloc) catch @panic("OOM");
    b.add(alloc, fdp.ConsumeIntegralInRange(u32, range_start, range_end)) catch @panic("OOM");
    if (false) std.debug.print("{} data_b {any} {f}\n", .{ size, bitmap_data_b.items, b });
}

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const zroaring = @import("root.zig");
const Bitmap = zroaring.Bitmap;
