/// a tagged pointer
pub const Container = struct {
    tagged: ?*align(1) [C.CONTAINER_SIZE_IN_BYTES]u8,
    // tag: Typecode, // TODO s/address/id
    // address: Address,
    // const Address = @Type(.{ .int = .{
    //     .bits = @bitSizeOf(usize) - @bitSizeOf(Typecode),
    //     .signedness = .signed,
    // } });

    pub const zero = mem.zeroes(Container);

    pub fn init(c: anytype) Container {
        const address = @intFromPtr(c);
        assert(@typeInfo(Typecode).@"enum".fields.len == 4);
        assert(address & 0b11 == 0);
        return .{ .tagged = @ptrFromInt(address |
            @intFromEnum(Typecode.fromType(@TypeOf(c.*)))) };
    }

    /// c must be a container type such as ArrayContainer
    pub fn create_from_value(allocator: mem.Allocator, c: anytype) !Container {
        const T = @TypeOf(c);
        return switch (T) {
            ArrayContainer, BitsetContainer, RunContainer, SharedContainer => {
                const ret = try allocator.create(T);
                // std.debug.print("create_from_value {s} {f}\n", .{ @typeName(T), c });
                ret.* = c;
                return .init(ret);
            },
            else => @compileError("non container type: " ++ @typeName(T)),
        };
    }

    pub fn deinit(c: Container, allocator: mem.Allocator) void {
        switch (c.typecode()) {
            inline else => |tc| {
                // std.debug.print("Container.deinit() {t} {f}\n", .{ tc, c.mut_cast(tc) });
                c.mut_cast(tc).deinit(allocator);
                allocator.destroy(c.mut_cast(tc));
            },
            _ => unreachable,
        }
    }

    pub fn ptr(c: Container) *anyopaque {
        return @ptrFromInt(@intFromPtr(c.tagged) & ~@as(usize, 0b11));
    }

    pub fn is_null(c: Container) bool {
        return c.tagged == null;
    }

    pub fn typecode(c: Container) Typecode {
        return @enumFromInt(@intFromPtr(c.tagged) & 0b11);
    }
    pub fn get_cardinality(c: Container) u64 {
        return switch (c.typecode()) {
            inline else => |tc| c.const_cast(tc).cardinality,
            .run => c.const_cast(.run).get_cardinality_scalar(), // TODO avx2, avx512
            .shared, _ => unreachable, // TODO
        };
    }

    pub fn get_container_type(c: Container) Typecode {
        return if (c.typecode() == .shared)
            c.const_cast(.shared).container.typecode()
        else
            c.typecode();
    }

    ///
    /// Get the container size in bytes under portable serialization (see
    /// container_write), requires a
    /// typecode
    ///
    pub fn size_in_bytes(c: Container) usize {
        // std.debug.print("c {x}-{x}\n", .{ @intFromEnum(c.typecode()), c.tagged });
        const ret = switch (c.typecode()) {
            inline else => |tc| c.unwrap_shared().const_cast(tc).size_in_bytes(),
            _ => unreachable,
        };
        // std.debug.print("Container.size_in_bytes {t} {}\n", .{ c.typecode(), ret });
        return ret;
    }

    pub fn unwrap_shared(candidate_shared_container: Container) Container {
        // /* access to container underneath */
        // static inline const container_t *container_unwrap_shared(
        // const container_t *candidate_shared_container, uint8_t *type) {
        if (candidate_shared_container.typecode() == .shared) {
            assert(candidate_shared_container.const_cast(.shared).container.typecode() != .shared);
            return candidate_shared_container.const_cast(.shared).container;
        } else {
            return candidate_shared_container;
        }
    }

    // /* access to container underneath, cloning it if needed */
    pub fn get_writable_copy_if_shared(c: Container) Container {
        if (c.typecode() == .shared) { // shared, return enclosed container
            // return shared_container_extract_copy(CAST_shared(c), type);
            unreachable; // TODO
        } else {
            return c; // not shared, so return as-is
        }
    }

    pub fn const_cast(c: Container, comptime tc: Typecode) *const tc.Type() {
        return @ptrCast(@alignCast(c.ptr()));
    }

    pub fn mut_cast(c: Container, comptime tc: Typecode) *tc.Type() {
        return @ptrCast(@alignCast(c.ptr()));
    }

    pub fn add(c: Container, allocator: mem.Allocator, val: u16) !Container {
        // TODO // const c = get_writable_copy_if_shared(c, &typecode);
        switch (c.typecode()) {
            .bitset => {
                _ = c.mut_cast(.bitset).set(val);
                return c;
            },
            .array => {
                const ac: *ArrayContainer = c.mut_cast(.array);
                const ok = try ac.try_add(allocator, val, C.DEFAULT_MAX_SIZE) != .not_added;
                if (ok) return .init(ac);

                const bitset = try allocator.create(BitsetContainer);
                errdefer allocator.destroy(bitset);
                bitset.* = try ac.bitset_container_from_array(allocator);
                _ = bitset.set(val);
                return .init(bitset);
            },
            .run => {
                // per Java, no container type adjustments are done (revisit?)
                _ = try c.mut_cast(.run).add(allocator, val); //
                return c;
            },
            .shared, _ => unreachable, // TODO
        }
    }

    pub fn add_assume_capacity(c: Container, hb: u16, tc: Typecode) void {
        _ = hb;
        _ = tc;
        _ = c;
        unreachable; // TODO
    }

    ///
    /// Writes the underlying array to buf, outputs how many bytes were written.
    /// This is meant to be byte-by-byte compatible with the Java and Go versions of
    /// Roaring.
    /// The number of bytes written should be
    /// container_write(container, buf).
    ///
    pub fn write(c: Container, w: *Io.Writer) !usize {
        const c1 = c.unwrap_shared();
        return switch (c1.typecode()) {
            inline else => |tc| try c1.const_cast(tc).write(w),
            .shared, _ => unreachable, // TODO
        };
    }

    pub fn contains(c: Container, val: u16) bool {
        const c1 = c.unwrap_shared();
        return switch (c1.typecode()) {
            inline else => |tc| c1.const_cast(tc).contains(val),
            .shared, _ => unreachable,
        };
    }

    pub fn equals(c1: Container, c2: Container) bool {
        const c1u = c1.unwrap_shared();
        const c2u = c2.unwrap_shared();

        return switch (c1u.typecode().pair(c2u.typecode())) { // PAIR_CONTAINER_TYPES(type1, type2)) {
            Typecode.pair(.bitset, .bitset) => c1u.const_cast(.bitset)
                .equals(c2u.const_cast(.bitset)),
            Typecode.pair(.array, .array) => c1u.const_cast(.array)
                .equals(c2u.const_cast(.array)),
            Typecode.pair(.run, .run) => c1u.const_cast(.run)
                .equals(c2u.const_cast(.run)),

            else => {
                std.debug.print("Conatiner.equals(). TODO pair ({t}, {t})\n", .{ c1u.typecode(), c2u.typecode() });
                unreachable;
            },
            //     case CONTAINER_PAIR(BITSET, BITSET):
            //         return bitset_container_equals(const_CAST_bitset(c1),
            //                                        const_CAST_bitset(c2));

            //     case CONTAINER_PAIR(BITSET, RUN):
            //         return run_container_equals_bitset(const_CAST_run(c2),
            //                                            const_CAST_bitset(c1));

            //     case CONTAINER_PAIR(RUN, BITSET):
            //         return run_container_equals_bitset(const_CAST_run(c1),
            //                                            const_CAST_bitset(c2));

            //     case CONTAINER_PAIR(BITSET, ARRAY):
            //         // java would always return false?
            //         return ArrayContainer.equal_bitset(const_CAST_array(c2),
            //                                             const_CAST_bitset(c1));

            //     case CONTAINER_PAIR(ARRAY, BITSET):
            //         // java would always return false?
            //         return ArrayContainer.equal_bitset(const_CAST_array(c1),
            //                                             const_CAST_bitset(c2));

            //     case CONTAINER_PAIR(ARRAY, RUN):
            //         return run_container_equals_array(const_CAST_run(c2),
            //                                           const_CAST_array(c1));

            //     case CONTAINER_PAIR(RUN, ARRAY):
            //         return run_container_equals_array(const_CAST_run(c1),
            //                                           const_CAST_array(c2));

            //     case CONTAINER_PAIR(ARRAY, ARRAY):
            //         return ArrayContainer.equals(const_CAST_array(c1),
            //                                       const_CAST_array(c2));

            //     case CONTAINER_PAIR(RUN, RUN):
            //         return run_container_equals(const_CAST_run(c1), const_CAST_run(c2));

            //     default:
            //         assert(false);
            //         roaring_unreachable;
            //         return false;
            // }
        };
    }

    ///
    ///Create new container which is a union of run container and
    ///range [min, max]. Caller is responsible for freeing run container.
    ///
    pub fn from_run_range(run: *const RunContainer, min: u32, max: u32) Container {
        _ = run;
        _ = min;
        _ = max;
        unreachable;
    }

    ///
    /// Add all values in range [min, max] to a given container.
    ///
    /// If the returned pointer is different from $container, then a new container
    /// has been created and the caller is responsible for freeing it.
    /// The type of the first container may change. Returns the modified
    /// (and possibly new) container.
    ///
    pub fn add_range(c: Container, allocator: mem.Allocator, min: u32, max: u32) !Container {
        // NB: when selecting new container type, we perform only inexpensive checks
        switch (c.typecode()) {
            .bitset => {
                const bitset = c.mut_cast(.bitset);

                var union_cardinality: u32 = 0;
                union_cardinality += bitset.cardinality;
                union_cardinality += max - min + 1;
                union_cardinality -=
                    BitsetContainer.lenrange_cardinality(bitset.words, min, max - min);

                if (union_cardinality == C.MAX_CARDINALITY) {
                    return try create_from_value(allocator, try RunContainer.init_range(allocator, 0, C.MAX_CARDINALITY));
                } else {
                    BitsetContainer.set_lenrange(bitset.words, min, max - min);
                    bitset.cardinality = union_cardinality;
                    return c;
                }
            },
            .array => {
                const array = c.mut_cast(.array);
                const nvals_greater = misc.count_greater(array.slice(), @truncate(max));
                const nvals_less = misc.count_less(array.slice()[0 .. array.cardinality - nvals_greater], @truncate(min));
                const union_cardinality = nvals_less + (max - min + 1) + nvals_greater;

                if (union_cardinality == C.MAX_CARDINALITY) {
                    return try create_from_value(allocator, try RunContainer.init_range(allocator, 0, C.MAX_CARDINALITY));
                } else if (union_cardinality <= C.DEFAULT_MAX_SIZE) {
                    try array.add_range_nvals(allocator, min, max, nvals_less, nvals_greater);
                    return c;
                } else {
                    var bitset = try array.to_bitset_container(allocator);
                    BitsetContainer.set_lenrange(bitset.words, min, max - min);
                    bitset.cardinality = union_cardinality;
                    return try create_from_value(allocator, bitset);
                }
            },
            .run => {
                const run = c.mut_cast(.run);
                const nruns_greater =
                    misc.rle16_count_greater(run.slice(), @truncate(max));
                const nruns_less =
                    misc.rle16_count_less(run.runs[0 .. run.n_runs - nruns_greater], @truncate(min));

                const run_size_bytes =
                    (nruns_less + 1 + nruns_greater) * @sizeOf(root.Rle16);
                const bitset_size_bytes =
                    BitsetContainer.SIZE_IN_WORDS * @sizeOf(u64);

                if (run_size_bytes <= bitset_size_bytes) {
                    try run.add_range_nruns(allocator, min, max, nruns_less, nruns_greater);
                    return c;
                } else {
                    return from_run_range(run, min, max);
                }
            },
            .shared, _ => unreachable, // TODO
        }
    }

    ///
    /// make a container with a run of ones
    ///
    /// initially always use a run container, even if an array might be
    /// marginally smaller
    pub fn range_of_ones(allocator: mem.Allocator, range_start: u32, range_end: u32) !Container {
        // std.debug.print("Container.range_of_ones {}-{}\n", .{ range_start, range_end });
        assert(range_end >= range_start);
        const cardinality = range_end - range_start + 1;
        return try if (cardinality <= 2)
            create_from_value(allocator, try ArrayContainer.init_range(allocator, range_start, range_end))
        else
            create_from_value(allocator, try RunContainer.init_range(allocator, range_start, range_end));
    }

    /// Create a container with all the values between in [min,max) at a
    /// distance k*step from min.
    pub fn from_range(allocator: mem.Allocator, min: u32, max: u32, step: u16) !Container {
        // std.debug.print("Container.from_range {}-{} step {}\n", .{ min, max, step });
        if (step == 0) return .zero; // being paranoid
        if (step == 1) {
            return try range_of_ones(allocator, min, max);
        }
        const size = (max - min + step - 1) / step;
        if (size <= C.DEFAULT_MAX_SIZE) { // array container
            var array = try ArrayContainer.init_with_capacity(allocator, size);
            try array.add_from_range(allocator, min, max, step);
            assert(array.cardinality == size);
            return try create_from_value(allocator, array);
        } else { // bitset container
            var bitset = try BitsetContainer.create(allocator);
            bitset.add_range(min, max, step);
            assert(bitset.cardinality == size);
            return try create_from_value(allocator, bitset);
        }
    }

    /// once converted, the original container is disposed here, rather than
    /// in roaring_array
    ///
    // TODO: split into run-  array-  and bitset-  subfunctions for sanity;
    // a few function calls won't really matter.
    pub fn convert_run_optimize(c: Container, allocator: mem.Allocator) !Container {
        if (c.typecode() == .run) {
            const newc = try c.mut_cast(.run).convert_run_to_efficient_container(allocator);
            if (newc.tagged != c.tagged) c.deinit(allocator);
            return newc;
        } else if (c.typecode() == .array) {
            // it might need to be converted to a run container.
            const c_qua_array = c.const_cast(.array);
            const n_runs = c_qua_array.number_of_runs();
            const size_as_run_container = RunContainer.serialized_size_in_bytes(n_runs);
            const card = c_qua_array.cardinality;
            const size_as_array_container = ArrayContainer.serialized_size_in_bytes(card);

            if (size_as_run_container >= size_as_array_container) {
                return c;
            }
            // else convert array to run container
            var answer = try RunContainer.init_with_capacity(allocator, n_runs);
            var prev: i32 = -2;
            var run_start: i32 = -1;

            assert(card > 0);
            var i: u32 = 0;
            while (i < card) : (i += 1) {
                const cur_val = c_qua_array.array[i];
                if (cur_val != prev + 1) {
                    // new run starts; flush old one, if any
                    if (run_start != -1) answer.add_run(@intCast(run_start), @intCast(prev));
                    run_start = cur_val;
                }
                prev = c_qua_array.array[i];
            }
            assert(run_start >= 0);
            // now prev is the last seen value
            answer.add_run(@intCast(run_start), @intCast(prev));
            c.deinit(allocator);
            return try .create_from_value(allocator, answer);
        } else if (c.typecode() == .bitset) { // run conversions on bitset
            unreachable; // TODO
            // // does bitset need conversion to run?
            // bitset_container_t *c_qua_bitset = CAST_bitset(c);
            // int32_t n_runs = bitset_container_number_of_runs(c_qua_bitset);
            // int32_t size_as_run_container =
            //     run_container_serialized_size_in_bytes(n_runs);
            // int32_t size_as_bitset_container =
            //     bitset_container_serialized_size_in_bytes();

            // if (size_as_bitset_container <= size_as_run_container) {
            //     // no conversion needed.
            //     *typecode_after = .bitset;
            //     return c;
            // }
            // // bitset to runcontainer (ported from Java  RunContainer(
            // // BitmapContainer bc, int nbrRuns))
            // assert(n_runs > 0);  // no empty bitmaps
            // run_container_t *answer = run_container_create_given_capacity(n_runs);

            // int long_ctr = 0;
            // uint64_t cur_word = c_qua_bitset.words[0];
            // while (true) {
            //     while (cur_word == UINT64_C(0) &&
            //            long_ctr < BITSET_CONTAINER_SIZE_IN_WORDS - 1)
            //         cur_word = c_qua_bitset.words[++long_ctr];

            //     if (cur_word == UINT64_C(0)) {
            //         bitset_container_free(c_qua_bitset);
            //         *typecode_after = .run;
            //         return answer;
            //     }

            //     int local_run_start = roaring_trailing_zeroes(cur_word);
            //     int run_start = local_run_start + 64 * long_ctr;
            //     uint64_t cur_word_with_1s = cur_word | (cur_word - 1);

            //     int run_end = 0;
            //     while (cur_word_with_1s == UINT64_C(0xFFFFFFFFFFFFFFFF) &&
            //            long_ctr < BITSET_CONTAINER_SIZE_IN_WORDS - 1)
            //         cur_word_with_1s = c_qua_bitset.words[++long_ctr];

            //     if (cur_word_with_1s == UINT64_C(0xFFFFFFFFFFFFFFFF)) {
            //         run_end = 64 + long_ctr * 64;  // exclusive, I guess
            //         add_run(answer, run_start, run_end - 1);
            //         bitset_container_free(c_qua_bitset);
            //         *typecode_after = .run;
            //         return answer;
            //     }
            //     int local_run_end = roaring_trailing_zeroes(~cur_word_with_1s);
            //     run_end = local_run_end + long_ctr * 64;
            //     add_run(answer, run_start, run_end - 1);
            //     cur_word = cur_word_with_1s & (cur_word_with_1s + 1);
            // }
            // return answer;
        } else {
            unreachable;
        }
    }
    pub fn internal_validate(container: Container, reason: *?[]const u8) bool {
        if (container.is_null()) {
            reason.* = "container is NULL";
            return false;
        }
        // Not using container_unwrap_shared because it asserts if shared containers
        // are nested
        if (container.typecode() == .shared) {}
        switch (container.typecode()) {
            .shared => {
                unreachable; // TODO
                // const shared_container_t *shared_container =
                //     const_CAST_shared(container);
                // if (croaring_refcount_get(&shared_container->counter) == 0) {
                //     reason.* = "shared container has zero refcount";
                //     return false;
                // }
                // if (shared_container->typecode == shared) {
                //     reason.* = "shared container is nested";
                //     return false;
                // }
                // if (shared_container->container.is_null()) {
                //     reason.* = "shared container has NULL container";
                //     return false;
                // }
                // container = shared_container->container;
                // typecode = shared_container->typecode;
            },
            inline .bitset, .array, .run => |t| return container.const_cast(t).validate(reason),
            //     bitset =>
            //         return bitset_container_validate(const_CAST_bitset(container),
            //                                          reason);
            // array =>
            //         return array_container_validate(const_CAST_array(container),
            //                                         reason);
            //         run =>
            //         return run_container_validate(const_CAST_run(container), reason);
            _ => {
                reason.* = "invalid typecode";
                return false;
            },
        }
    }

    pub fn format(c: Container, w: *Io.Writer) !void {
        // std.debug.print("{x}-{x}", .{ @intFromEnum(c.typecode()), c.tagged });
        switch (c.typecode()) {
            inline else => |tag| {
                try w.print("{t} ", .{tag});
                try c.const_cast(tag).format(w);
            },
            _ => {},
        }
    }
};

pub const BitsetContainer = @import("WordBitset.zig").WordBitset(.{});

pub const SharedContainer = struct {
    container: Container,
    /// to be managed atomically // TODO
    refcount: std.atomic.Value(u32),
    _96: u32,
    pub fn deinit(r: SharedContainer, allocator: mem.Allocator) void {
        r.container.deinit(allocator);
    }
    pub fn size_in_bytes(s: SharedContainer) usize {
        return s.container.size_in_bytes();
    }
    pub fn format(c: SharedContainer, w: *Io.Writer) error{WriteFailed}!void {
        try w.print("", .{});
        try c.container.format(w);
    }
};

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Io = std.Io;
const root = @import("root.zig");
const Typecode = root.Typecode;
const ArrayContainer = root.ArrayContainer;
const RunContainer = root.RunContainer;
const Array = root.Array;
const misc = @import("misc.zig");
const C = @import("constants.zig");
const types = @import("types.zig");
