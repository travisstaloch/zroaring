const word_types = &.{ u1024, u512, u256, u128, u64, u32, u16, u8 };

/// a bitmap which stores integers as offsets relative to `min`
/// * `min`, `max`: smallest and largest integers the bitmap can represent.
/// * `Word`: a integer word type such as u64.
pub fn Bitmap(min: comptime_int, max: comptime_int, Word: type) type {
    return struct {
        /// cached population count of set bits in words
        count: VCount,
        /// bitset stored as words with length padded to `words_len_padded`
        words: WordsPtrAligned,

        //                                               example: min = 0
        //                                                        max = 65535
        //                                                       Word = u64
        /// a integer type for min and max.
        pub const Value = std.math.IntFittingRange(min, max); //        u16
        /// positive difference between min and max
        pub const max_offset = max - min; //                            65535
        const max_count = max_offset + 1; //                            65536
        const VCount = std.math.IntFittingRange(0, max_offset); //      u17
        const Word_bits: usize = @typeInfo(Word).int.bits; //           64
        /// number of words without padding to block len                1024
        const words_len = std.math.divCeil(usize, max_count, Word_bits) catch unreachable;
        /// number of words with padding to block len                   1024
        const words_len_padded: usize = mem.alignForward(usize, words_len, block_len);
        const WordsPtrAligned = *align(block_align) [words_len_padded]Word;
        pub const size_in_bytes = words_len_padded * @sizeOf(Word); //  8192
        const WordIndex = std.math.Log2Int(Word); //                    u6

        // blocks
        /// suggested vector length for `Word` or else largest suggested from `block_types`.
        const block_len = std.simd.suggestVectorLength(Word) orelse
            for (word_types) |T| {
                if (std.simd.suggestVectorLength(T)) |len|
                    break len;
            } else null; // unsupported. TODO. workaround use another Word type
        const Block = @Vector(@min(words_len_padded, block_len), Word);
        const BlockArray = [@min(words_len_padded, block_len)]Word;
        const block_align = @alignOf(Block);
        const blocks_count = words_len_padded / block_len;
        const words_per_block = words_len_padded / blocks_count;
        const BlockMask = std.meta.Int(.unsigned, @sizeOf(Block) * 8);

        const Self = @This();

        pub fn init(words: WordsPtrAligned) Self {
            words.* = @splat(0);
            return .{ .words = words, .count = 0 };
        }

        pub fn initBatch(words: WordsPtrAligned, values: []const Value) Self {
            var ret = init(words);
            return ret.putBatch(values).*;
        }

        pub fn create(allocator: mem.Allocator) !Self {
            const words_slice = try allocator.alignedAlloc(Word, .fromByteUnits(block_align), words_len_padded);
            return init(words_slice[0..words_len_padded]);
        }

        pub fn createBatch(allocator: mem.Allocator, values: []const Value) !Self {
            const words_slice = try allocator.alignedAlloc(Word, .fromByteUnits(block_align), words_len_padded);
            return initBatch(words_slice[0..words_len_padded], values);
        }

        pub fn destroy(self: Self, allocator: mem.Allocator) void {
            return allocator.destroy(self.words);
        }

        pub fn put(self: *Self, value: Value) *Self {

            // TODO optimize like roaring?
            // uint64_t shift = 6;
            // uint64_t offset;
            // uint64_t p = pos;
            // ASM_SHIFT_RIGHT(p, shift, offset);
            // uint64_t load = bitset->words[offset];
            // ASM_SET_BIT_INC_WAS_CLEAR(load, p, bitset->count);
            // bitset->words[offset] = load;
            // std.debug.print("set({}) min {}\n", .{ v2, min });

            const offset = value - min;
            const word_idx = offset / Word_bits;
            // std.log.debug("{f}", .{self.*});
            // std.debug.print("value/offset {}/{} word_idx {}/{}\n", .{ value, offset, word_idx, max_words });
            const bit_idx: WordIndex = @intCast(offset % Word_bits);
            const word = &self.words[word_idx];
            const is_unset = 1 - @as(u1, @intCast((word.* >> bit_idx) & 1));
            self.count += is_unset;
            // std.debug.print("{} {}\n", .{ self.count, max_count });
            assert(self.count <= max_count);
            word.* |= (@as(Word, 1) << @intCast(bit_idx));
            return self;
        }

        pub fn putBatch(self: *Self, values: []const Value) *Self {
            for (values) |v| _ = self.put(v);
            return self;
        }

        pub fn unset(self: *Self, v2: Value) *Self {
            const value = v2 - min;
            const word_idx = value / Word_bits;
            const bit_idx = value % Word_bits;
            self.words[word_idx] &= ~(@as(Word, 1) << @intCast(bit_idx));
            return self;
        }

        pub fn contains(self: Self, v2: Value) bool {
            const value = v2 - min;
            const word_idx = value / Word_bits;
            const bit_idx = value % Word_bits;
            // std.debug.print("--\n{} {} {}\n{b:0>64}\n{b:0>64}\n", .{ value, word_idx, bit_idx, self.words[word_idx], @as(Word, 1) << @intCast(bit_idx) });
            return (self.words[word_idx] & (@as(Word, 1) << @intCast(bit_idx))) != 0;
        }

        pub fn containsBatch(self: Self, values: []const Value) bool {
            for (values) |v| if (!self.contains(v)) return false;
            return true;
        }

        // fn calcCount(self: Self) VCount {
        //     var count: VCount = 0;
        //     for (self.words) |word| count += @intCast(@popCount(word));
        //     return count;
        // }

        pub const Op = enum { @"|", @"&", @"&~", @"^" };

        // TODO benchmark, test this is faster than per-word ops
        /// perform `op` on blocks at once instead of individual words.
        fn blockOp(dest: *Self, src: Self, comptime op: Op) *Self {
            assert(blocks_count > 0);
            dest.count = 0;
            for (0..blocks_count) |blocki| {
                const d: *BlockArray = @ptrCast(dest.words[blocki * words_per_block ..][0..words_per_block]);
                const s: *BlockArray = @ptrCast(src.words[blocki * words_per_block ..][0..words_per_block]);
                var dv: Block = d.*;
                const sv: Block = s.*;
                dv = switch (op) {
                    .@"|" => dv | sv,
                    .@"&" => dv & sv,
                    .@"&~" => dv & ~sv,
                    .@"^" => dv ^ sv,
                };
                d.* = dv;
                dest.count += @intCast(@popCount(@as(BlockMask, @bitCast(dv))));
            }
            return dest;
        }

        pub const unionWith = unionWithSimd; // TODO fallback to words
        fn unionWithWords(self: *Self, other: Self) *Self {
            self.count = 0;
            for (self.words, other.words) |*s, *o| {
                s.* |= o.*;
                self.count += @intCast(@popCount(s.*));
            }
            return self;
        }
        fn unionWithSimd(self: *Self, other: Self) *Self {
            return self.blockOp(other, .@"|");
        }

        pub const intersectWith = intersectWithSimd; // TODO fallback to words
        fn intersectWithWords(self: *Self, other: Self) *Self {
            self.count = 0;
            for (self.words, other.words) |*s, *o| { // TODO bench and compare
                s.* &= o.*;
                self.count += @intCast(@popCount(s.*));
            }
            return self;
        }
        fn intersectWithSimd(self: *Self, other: Self) *Self {
            return self.blockOp(other, .@"&");
        }

        pub fn clear(self: *Self) *Self {
            self.words.* = @splat(0);
            self.count = 0;
            return self;
        }

        pub const differenceWith = differenceWithSimd; // TODO fallback to words
        fn differenceWithWords(self: *Self, other: Self) *Self {
            self.count = 0;
            for (self.words, other.words) |*s, *o| { // TODO bench and compare
                s.* &= ~o.*;
                self.count += @intCast(@popCount(s.*));
            }
            return self;
        }
        fn differenceWithSimd(self: *Self, other: Self) *Self {
            return self.blockOp(other, .@"&~");
        }

        pub const xorWith = xorWithSimd; // TODO fallback to words
        fn xorWithWords(self: *Self, other: Self) *Self {
            self.count = 0;
            for (self.words, other.words) |*s, *o| { // TODO bench and compare
                s.* ^= o.*;
                self.count += @intCast(@popCount(s.*));
            }
            return self;
        }
        fn xorWithSimd(self: *Self, other: Self) *Self {
            return self.blockOp(other, .@"^");
        }

        pub fn isEmpty(self: Self) bool {
            return self.count == 0;
        }

        pub fn equals(self: *const Self, other: *const Self) bool {
            for (self.words, other.words) |*s, *o| { // TODO optimize?
                if (s.* != o.*) return false;
            }
            return true;
        }

        pub fn copy(self: *Self, other: Self) *Self {
            for (self.words, other.words) |*s, *o| { // TODO optimize?
                s.* = o.*;
            }
            self.count = other.count;
            return self;
        }

        /// this may be a large struct and likely shouldn't be copied
        pub const Builder = struct {
            words: [words_len_padded]Word align(block_align),
            bitmap: Self,

            pub fn init(b: *Builder) Self {
                b.bitmap = .init(&b.words);
                return b.bitmap;
            }
            pub fn initBatch(b: *Builder, values: []const Value) Self {
                b.bitmap = .initBatch(&b.words, values);
                return b.bitmap;
            }
        };

        pub fn format(self: Self, w: *std.Io.Writer) !void {
            try w.print("{}", .{self.count});
            if (build_options.trace) {
                try w.print(
                    " Bitmap({: <4}{: <6}{: <5}) value types: {: <3} {: <3} words (needed: {: <5} padded: {: <5} bytes: {: <5}) block: {s: <6} mask: {} blocks {}",
                    .{ min, max, Word, Value, VCount, words_len, words_len_padded, size_in_bytes, @typeName(Word) ++ std.fmt.comptimePrint("x{}", .{block_len}), BlockMask, blocks_count },
                );
            }
        }

        test {
            _ = TestNs(min, max, Word);
        }
    };
}

/// internal namespace of tests
// TODO how to make these tests show up in zig docs?  moved here in attempt of that.
fn TestNs(min: comptime_int, max: comptime_int, Word: type) type {
    return struct {
        const B = Bitmap(min, max, Word);
        const Builder = B.Builder;

        test Builder {
            var b: Builder = undefined;
            try testing.expectEqual(b.init().count, 0);
            try testing.expectEqual(b.initBatch(&.{ min, min + 1 }).count, 2);
        }

        const format = B.format;
        test format {
            var b: Builder = undefined;
            if (!build_options.trace) {
                try testing.expectFmt("0\n", "{f}\n", .{b.init()});
                try testing.expectFmt("2\n", "{f}\n", .{b.initBatch(&.{ min, min + 1 })});
            } else {
                std.debug.print("{f}\n", .{b.init()});
                // std.debug.print("{f}\n", .{b.initBatch(&.{ min, min + 1 })});
            }
        }

        const init = B.init;
        test init {
            var b: Builder = undefined;
            try testing.expectEqual(b.init().count, 0);
        }

        const create = B.create;
        test create {
            const c = try create(testing.allocator);
            defer c.destroy(testing.allocator);
            try testing.expectEqual(c.count, 0);
        }

        const createBatch = B.createBatch;
        test createBatch {
            const c = try createBatch(testing.allocator, &.{ min, max });
            defer c.destroy(testing.allocator);
            try testing.expectEqual(c.count, 2);
        }

        const va = min + B.max_offset / 8 - 1;
        const vb = min + B.max_offset / 8;

        const put = B.put;
        test put {
            var b: Builder = undefined;
            var container = b.initBatch(&.{ min, va, vb, max - 1 });
            try testing.expect(container.containsBatch(&.{ min, va, vb, max - 1 }));
        }

        const unset = B.unset;
        test unset {
            var b: Builder = undefined;
            const n = min + B.max_offset / 2;
            var c = b.initBatch(&.{n});
            try testing.expect(!c.unset(n).contains(n));
        }

        test "count" {
            var b: Builder = undefined;
            var container = b.init();
            try testing.expectEqual(1, container.put(min + 10).count);
            try testing.expectEqual(2, container.put(min + 20).count);
            try testing.expectEqual(2, container.put(min + 10).count);
        }

        const unionWith = B.unionWith;
        test unionWith {
            var b: Builder = undefined;
            var b2: Builder = undefined;
            var c1 = b.initBatch(&.{ min + 5, min + 10 });
            const c2 = b2.initBatch(&.{ min + 10, min + 15 });
            try testing.expect(c1.unionWith(c2).containsBatch(&.{ min + 5, min + 10, min + 15 }));
            try testing.expectEqual(3, c1.count);
        }

        const intersectWith = B.intersectWith;
        test intersectWith {
            var b: Builder = undefined;
            var b2: Builder = undefined;
            var c1 = b.initBatch(&.{ min + 5, min + 10, min + 15 });
            const c2 = b2.initBatch(&.{ min + 10, min + 15, min + 20 });
            _ = c1.intersectWith(c2);
            try testing.expect(!c1.containsBatch(&.{ min + 5, min + 20 }));
            try testing.expect(c1.containsBatch(&.{ min + 10, min + 15 }));
            try testing.expectEqual(2, c1.count);
        }

        const clear = B.clear;
        test clear {
            var b: Builder = undefined;
            var container = b.initBatch(&.{ min + 5, min + B.max_offset / 3, min + B.max_offset - 1 });
            try testing.expectEqual(container.count, 3);
            try testing.expectEqual(container.clear().count, 0);
            try testing.expect(!container.contains(min + 5));
        }

        test "word boundaries" {
            var b: Builder = undefined;
            var container = b.initBatch(&.{ va, vb });
            try testing.expect(container.containsBatch(&.{ va, vb }));
            try testing.expectEqual(container.count, 2);
        }

        test "large values" {
            var b: Builder = undefined;
            const container = b.initBatch(&.{ max - 1, max - 2 });
            try testing.expect(container.contains(max - 1));
            try testing.expect(container.contains(max - 2));
            try testing.expectEqual(container.count, 2);
        }

        const differenceWith = B.differenceWith;
        test differenceWith {
            var b: Builder = undefined;
            var b2: Builder = undefined;
            var c1 = b.initBatch(&.{ min + 5, min + 10, min + 15 });
            _ = c1.differenceWith(b2.initBatch(&.{ min + 10, min + 15, min + 20 }));
            try testing.expect(c1.contains(min + 5));
            try testing.expect(!c1.containsBatch(&.{ min + 10, min + 15, min + 20 }));
            try testing.expectEqual(c1.count, 1);
        }

        const xorWith = B.xorWith;
        test xorWith {
            var b: Builder = undefined;
            var b2: Builder = undefined;
            var c1 = b.initBatch(&.{ min + 5, min + 10, min + 15 });
            _ = c1.xorWith(b2.initBatch(&.{ min + 10, min + 15, min + 20 }));
            try testing.expect(c1.contains(min + 5));
            try testing.expect(!c1.contains(min + 10));
            try testing.expect(!c1.contains(min + 15));
            try testing.expect(c1.contains(min + 20));
            try testing.expectEqual(c1.count, 2);
        }

        const isEmpty = B.isEmpty;
        test isEmpty {
            var b: Builder = undefined;
            var container = b.init();
            try testing.expect(container.isEmpty());
            try testing.expect(!container.put(min + B.max_offset / 3).isEmpty());
        }

        const equals = B.equals;
        test equals {
            var b: Builder = undefined;
            var b2: Builder = undefined;
            const c1 = b.initBatch(&.{ min + 5, min + 10 });
            var c2 = b2.initBatch(&.{ min + 5, min + 10 });
            try testing.expect(c1.equals(&c2));
            try testing.expect(!c1.equals(c2.put(min + 15)));
        }

        const copy = B.copy;
        test copy {
            var bsrc: Builder = undefined;
            var bdst: Builder = undefined;
            var dst = bdst.init();
            _ = dst.copy(bsrc.initBatch(&.{ min + 5, min + B.max_offset / 3, min + B.max_offset - 1 }));
            try testing.expect(dst.contains(min + 5));
            try testing.expect(dst.contains(min + B.max_offset / 3));
            try testing.expect(dst.contains(min + B.max_offset - 1));
            try testing.expectEqual(dst.count, 3);
        }

        test "dense region" {
            var b: Builder = undefined;
            var container = b.init();
            const n = @min(max + 1, min + B.max_offset / 9);
            for (min..n) |i| _ = container.put(@intCast(i));
            try testing.expectEqual(n - min, @as(usize, container.count));
            for (min..n) |i| try testing.expect(container.contains(@intCast(i)));
        }

        test "sparse region" {
            var b: Builder = undefined;
            const vs = &.{ min, min + B.max_offset / 3, min + B.max_offset / 2, min + B.max_offset - 1 };
            const container = b.initBatch(vs);
            try testing.expectEqual(4, container.count);
            try testing.expect(container.containsBatch(vs));
        }

        test "alternating pattern" {
            var b: Builder = undefined;
            var container = b.init();
            const n = @min(max, min + (B.max_offset - 1) / 8);
            for (min..n) |i| {
                if (i % 2 == 0) _ = container.put(@intCast(i));
            }
            try testing.expectEqual((n - min) / 2 + (n & 1), container.count);
            for (min..n) |i| {
                const expected = i % 2 == 0;
                try testing.expectEqual(expected, container.contains(@intCast(i)));
            }
        }

        test "multiple unions" {
            var b1: Builder = undefined;
            var b2: Builder = undefined;
            var b3: Builder = undefined;
            var c1 = b1.initBatch(&.{min + 5});
            _ = c1.unionWith(b2.initBatch(&.{min + 10}))
                .unionWith(b3.initBatch(&.{min + 15}));
            try testing.expectEqual(3, c1.count);
            try testing.expect(c1.containsBatch(&.{ min + 5, min + 10, min + 15 }));
        }

        test "intersection with empty" {
            var b: Builder = undefined;
            var b2: Builder = undefined;
            var c1 = b.initBatch(&.{ min + 5, min + 10 });
            try testing.expectEqual(0, c1.intersectWith(b2.init()).count);
        }
    };
}

/// returns an empty bitmap backed by `words`
pub fn bitmap(
    min: comptime_int,
    max: comptime_int,
    Word: type,
    words: Bitmap(min, max, Word).WordsPtrAligned,
) Bitmap(min, max, Word) {
    return .init(words);
}

/// returns a bitmap backed by `words` with the given batch of values
pub fn bitmapBatch(
    min: comptime_int,
    max: comptime_int,
    Word: type,
    words: Bitmap(min, max, Word).WordsPtrAligned,
    values: []const Bitmap(min, max, Word).Value,
) Bitmap(min, max, Word) {
    return .initBatch(words, values);
}

/// causes tests inside Bitmap(min, max, W) to be analyzed and run
fn testBitmap(min: comptime_int, max: comptime_int, W: type) !void {
    const Map = Bitmap(min, max, W);
    var b: Map.Builder = undefined;
    _ = b.init();
    _ = b.initBatch(&.{});
}

test bitmap {
    try testBitmap(0, 65535, u32);
    try testBitmap(0, 65535, u64);
    try testBitmap(0, 65536, u64);
    try testBitmap(0, 65535 / 2, u64);
    try testBitmap(0, 127, u64);
    try testBitmap(128, 255, u64);

    try testBitmap(0, 65535, u128);
    try testBitmap(0, 255, u128);

    try testBitmap(0, 65535, u256);
    try testBitmap(0, 255, u256);

    inline for (word_types) |word_type|
        try testBitmap(0, 65535, @Type(.{ .int = .{
            .bits = @bitSizeOf(word_type),
            .signedness = .unsigned,
        } }));
}

test "small range - a...z" {
    const B = Bitmap('a', 'z', u64);
    var b: B.Builder = undefined;
    try testing.expect(b.initBatch(&.{ 'a', 'z' }).containsBatch(&.{ 'a', 'z' }));
    for ('b'..'z') |c| {
        try testing.expect(!b.bitmap.contains(@intCast(c)));
    }
    try testing.expectEqual(2, b.bitmap.count);
}

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const assert = std.debug.assert;
const build_options = @import("build-options");
