const Bitmap = @This();

header: Header,
pool: std.ArrayList(C.Block),

pub const empty: Bitmap = .{ .header = mem.zeroes(Header), .pool = .empty };

pub const KeyCard = extern struct { key: u16, cardinality_minus1: u16 };

const Container = packed struct(u64) {
    /// an offset into the data pool.  where the container data starts.
    pool_offset: u32,
    n_blocks: u14,
    /// only used for runs.  undefined for bitsets and arrays.
    n_runs: u16,
    typecode: enum(u2) { shared, bitset, array, run },

    pub fn serialized_size_in_bytes(c: Container, card: u32) usize {
        return switch (c.typecode) {
            .array => @sizeOf(u16) * card,
            .run => @sizeOf(u16) + @sizeOf(root.Rle16) * c.n_runs,
            .bitset => @sizeOf(C.Bitset),
            .shared => unreachable,
        };
    }

    pub const size_in_bytes = serialized_size_in_bytes;
};

/// Designed for frequent updates.
/// Fields are ordered by decreasing alignment to reduce size.
/// All slices are allocated from a single allocation of length `buffer_size()`.
const Header = extern struct {
    /// of length `(container_count+7)/8` when runs are present, otherwise 0.
    run_flags: ?[*]u8,
    /// keys from `descriptive_header`.  of length `container_count`.
    keys: [*]u16,
    /// cardinalities from `descriptive_header` + 1.  of length `container_count`.
    cardinalities: [*]u32,
    /// of length `container_count`.
    containers: [*]Container,
    /// file position where header data ends and container data starts.  set during
    /// deserialization.
    container_startpos: u64, // TODO remove, calc when needed?
    container_count: u32,
    /// number of SIMD-register sized blocks in the pool.
    n_blocks: u32,
    magic: root.Magic,

    pub const ALIGNMENT: mem.Alignment = .fromByteUnits(@alignOf(Header));

    pub fn deinit(h: *Header, allocator: mem.Allocator) void {
        if (h.container_count == 0) return;
        var ptr: ?[*]u8 = if (h.can_have_run_containers())
            h.run_flags
        else
            @ptrCast(@alignCast(h.keys));
        const buf = ptr.?[0..h.buffer_size()];
        // std.debug.print("buf.len {} {*}\n", .{ buf.len, buf.ptr });
        allocator.free(buf);
    }

    pub fn can_have_run_containers(h: Header) bool {
        return h.magic == .SERIAL_COOKIE;
    }

    pub fn is_empty(h: Header) bool {
        return h.container_count == 0;
    }

    pub fn get_run_flags(h: Header) []u8 {
        return if (h.can_have_run_containers())
            h.run_flags.?[0 .. (h.container_count + 7) / 8]
        else
            &.{};
    }

    pub fn get_keys(h: Header) []u16 {
        return h.keys[0..h.container_count];
    }

    pub fn get_cards(h: Header) []u32 {
        return h.cardinalities[0..h.container_count];
    }

    pub fn get_containers(h: Header) []Container {
        return h.containers[0..h.container_count];
    }

    pub fn has_run_container(h: Header) bool {
        return for (h.get_containers()) |c| {
            if (c.typecode == .run) break true;
        } else false;
    }

    pub fn portable_size(h: Header) usize {
        const count = h.container_count;
        if (h.can_have_run_containers()) {
            return 4 + (count + 7) / 8 +
                if (count < C.NO_OFFSET_THRESHOLD) // for small bitmaps, we omit the offsets
                    4 * count
                else
                    8 * count; // - 4 because we pack the size with the cookie
        } else {
            return 4 + 4 + 8 * count; // no run flags, u32 cardinality,
        }
    }

    /// `containers` must have been populated such as after deserialize()
    pub fn portable_size_in_bytes(h: Header) usize {
        var count = h.portable_size();
        for (h.get_containers(), 0..) |c, i| {
            count += switch (c.typecode) {
                .array => h.cardinalities[i] * 2,
                .bitset => @sizeOf(C.Bitset),
                .run => @as(u32, c.n_runs) * 4,
                .shared => unreachable, // TODO
            };
        }
        return count;
    }

    /// how many bytes are needed to store header slices not including @sizeOf(Header).
    pub fn buffer_size_from_file(io: Io, bitmap_file: Io.File) !Info {
        var read_buf: [8]u8 = undefined;
        var freader = bitmap_file.reader(io, &read_buf);
        return buffer_size_from_file_reader(&freader);
    }

    const Info = struct {
        buffer_size: usize,
        cookie: root.Cookie,
        container_count: u32,
    };

    /// advances `freader` by 4 bytes or 8 bytes when there are runs
    pub fn buffer_size_from_file_reader(freader: *Io.File.Reader) !Info {
        assert(freader.logicalPos() == 0);
        const r = &freader.interface;
        const cookie = try r.takeStruct(root.Cookie, .little);
        if (cookie.magic != .SERIAL_COOKIE and
            cookie.magic != .SERIAL_COOKIE_NO_RUNCONTAINER)
            return error.UnexpectedCookie;

        const container_count = if (cookie.magic == .SERIAL_COOKIE)
            @as(u32, cookie.cardinality_minus1) + 1
        else
            try r.takeInt(u32, .little);

        return .{
            .cookie = cookie,
            .container_count = container_count,
            .buffer_size = buffer_size_from_magic_count(cookie.magic, container_count),
        };
    }

    /// includes @sizeOf(Header).
    /// tricky because we simulate the behavior of a fixed buffer allocator,
    /// aligning forward.  Order matters.  must be synced with Header.deserialize().
    /// TODO - discarding writer or some simpler way than this?
    pub fn buffer_size_from_magic_count(magic: root.Magic, container_count: u32) usize {
        const hasruns = magic == .SERIAL_COOKIE;
        var ret: usize = 0;
        // run_flags
        if (hasruns) ret += (container_count + 7) / 8;
        // keys
        ret = mem.alignForward(usize, ret + @sizeOf(u16) * container_count, @alignOf(u16));
        // cards
        ret = mem.alignForward(usize, ret + @sizeOf(u32) * container_count, @alignOf(u32));
        // file_offsets
        // if (!hasruns or (hasruns and container_count >= C.NO_OFFSET_THRESHOLD)) {
        //     ret = mem.alignForward(usize, ret + @sizeOf(u32) * container_count, @alignOf(u32));
        // }
        // containers
        ret = mem.alignForward(usize, ret + @sizeOf(Container) * container_count, @alignOf(Container));
        return ret;
    }

    pub fn buffer_size(h: Header) usize {
        return buffer_size_from_magic_count(h.magic, h.container_count);
    }

    pub fn deserialize(bitmap_file: Io.File, allocator: mem.Allocator, read_buf: []u8) !Header {
        var freader = bitmap_file.reader(read_buf);
        return deserialize_from_file_reader(allocator, &freader);
    }

    pub fn deserialize_from_file_reader(allocator: mem.Allocator, freader: *Io.File.Reader) !Header {
        const info = try Header.buffer_size_from_file_reader(freader);
        const header_buf = try allocator.alloc(u8, info.buffer_size);
        const r = &freader.interface;
        errdefer allocator.free(header_buf);
        var fba = std.heap.FixedBufferAllocator.init(header_buf);
        const bufalloc = fba.allocator();

        var ret: Header = mem.zeroes(Header);

        const cookie = info.cookie;
        ret.magic = cookie.magic;
        assert(cookie.magic == .SERIAL_COOKIE or cookie.magic == .SERIAL_COOKIE_NO_RUNCONTAINER);

        ret.container_count = info.container_count;
        assert(ret.container_count <= C.MAX_CONTAINERS); // data must be corrupted

        const hasruns = cookie.magic == .SERIAL_COOKIE;

        if (hasruns) {
            ret.run_flags = (try r.readAlloc(bufalloc, (ret.container_count + 7) / 8)).ptr;
        }
        ret.keys = (try bufalloc.alloc(u16, ret.container_count)).ptr;
        ret.cardinalities = (try bufalloc.alloc(u32, ret.container_count)).ptr;
        for (0..ret.container_count) |i| { // TODO maybe read N key_cards at a time, less looping here
            const kc = try r.takeStruct(KeyCard, .little);
            ret.keys[i] = kc.key;
            ret.cardinalities[i] = @as(u32, kc.cardinality_minus1) + 1;
        }

        // skip file offsets
        if (!hasruns or (hasruns and ret.container_count >= C.NO_OFFSET_THRESHOLD))
            _ = try r.discard(.limited(ret.container_count * @sizeOf(u32)));

        ret.containers = (try bufalloc.alloc(Container, ret.container_count)).ptr;

        ret.container_startpos = freader.logicalPos();
        assert(ret.container_startpos == ret.portable_size());

        for (0..ret.container_count) |k| { // calculate blocks needed to store containers
            const thiscard = ret.cardinalities[k];
            var isbitset = (thiscard > C.DEFAULT_MAX_SIZE);
            var isrun = false;
            if (hasruns and
                ((ret.run_flags.?[k / 8] & @as(u8, 1) << @truncate(k % 8))) != 0)
            {
                isbitset = false;
                isrun = true;
            }
            if (isbitset) {
                _ = try r.discard(.limited(@sizeOf(C.Bitset)));
                ret.n_blocks += C.BITSET_BLOCKS;
            } else if (isrun) {
                const n_runs: u32 = try r.takeInt(u16, .little);
                _ = try r.discard(.limited(n_runs * 4));
                const blocks_size = mem.alignForward(u32, n_runs * 4, C.BLOCK_LEN);
                ret.n_blocks += @divExact(blocks_size, C.BLOCK_LEN);
            } else {
                _ = try r.discard(.limited(thiscard * 2));
                const blocks_size = mem.alignForward(u32, thiscard * 2, C.BLOCK_LEN);
                ret.n_blocks += @divExact(blocks_size, C.BLOCK_LEN);
            }
        }
        assert(freader.size == null or freader.atEnd());
        return ret;
    }
};

test Header {
    // check Header has same size as an auto layout, HeaderAuto.
    const header_field_types = comptime blk: {
        const fs = @typeInfo(Header).@"struct".fields;
        var ret: [fs.len]type = undefined;
        for (fs, &ret) |f, *r| r.* = f.type;
        break :blk &ret;
    };
    const HeaderAuto = @Struct(.auto, null, std.meta.fieldNames(Header), header_field_types, &@splat(.{}));
    try testing.expectEqual(@sizeOf(Header), @sizeOf(HeaderAuto));
    try testing.expectEqual(56, @sizeOf(Header));

    const io = testing.io;
    {
        const f = try Io.Dir.cwd().openFile(io, "testdata/bitmapwithoutruns.bin", .{});
        defer f.close(io);
        try testing.expectEqual(160, (try Header.buffer_size_from_file(io, f)).buffer_size);
    }
    {
        const f = try Io.Dir.cwd().openFile(io, "testdata/bitmapwithruns.bin", .{});
        defer f.close(io);
        try testing.expectEqual(160, (try Header.buffer_size_from_file(io, f)).buffer_size);
    }
}

pub fn deinit(r: *Bitmap, allocator: mem.Allocator) void {
    r.pool.deinit(allocator);
    r.header.deinit(allocator);
}

/// Allocates and returns a Bitmap as 2 allocations, read from
/// `bitmap_file` which must be a seekable file.
/// `read_buf` is a temporary buffer.
/// TODO non-seekable files.
pub fn portable_deserialize(
    allocator: mem.Allocator,
    io: Io,
    bitmap_file: Io.File,
    read_buf: []u8,
) !Bitmap {
    var freader = bitmap_file.reader(io, read_buf);
    var header = try Header.deserialize_from_file_reader(allocator, &freader);
    errdefer header.deinit(allocator);

    // allocate container data
    var pool: std.ArrayList(C.Block) = try .initCapacity(allocator, header.n_blocks);
    errdefer pool.deinit(allocator);
    pool.expandToCapacity();

    // seek to start of container data and read containers into pool
    try freader.seekTo(header.container_startpos);
    var r = &freader.interface;

    var pool_offset: u32 = 0;
    for (0..header.container_count) |k| { // read container data
        const thiscard = header.cardinalities[k];
        var isbitset = (thiscard > C.DEFAULT_MAX_SIZE);
        var isrun = false;
        if (header.can_have_run_containers() and
            ((header.run_flags.?[k / 8] & @as(u8, 1) << @truncate(k % 8))) != 0)
        {
            isbitset = false;
            isrun = true;
        }
        if (isbitset) {
            try r.readSliceAll(mem.asBytes(pool.items[pool_offset..][0..C.BITSET_BLOCKS]));
            header.containers[k] = .{
                .pool_offset = pool_offset,
                .n_blocks = C.BITSET_BLOCKS,
                .n_runs = undefined,
                .typecode = .bitset,
            };
            pool_offset += C.BITSET_BLOCKS;
        } else if (isrun) {
            const n_runs: u32 = try r.takeInt(u16, .little);
            const blocks_size = mem.alignForward(u32, n_runs * 4, C.BLOCK_LEN);
            const n_blocks = @divExact(blocks_size, C.BLOCK_LEN);
            const blocks_bytes = mem.sliceAsBytes(pool.items[pool_offset..][0..n_blocks]);
            const run_slice = mem.bytesAsSlice(root.Rle16, blocks_bytes);
            try r.readSliceEndian(root.Rle16, run_slice[0..n_runs], .little);
            header.containers[k] = .{
                .pool_offset = pool_offset,
                .n_blocks = @intCast(n_blocks),
                .n_runs = @intCast(n_runs),
                .typecode = .run,
            };
            pool_offset += n_blocks;
        } else { // array container
            const blocks_size = mem.alignForward(u32, thiscard * 2, C.BLOCK_LEN);
            const n_blocks = @divExact(blocks_size, C.BLOCK_LEN);
            const blocks_bytes = mem.sliceAsBytes(pool.items[pool_offset..]);
            const values = mem.bytesAsSlice(u16, blocks_bytes);
            try r.readSliceEndian(u16, values[0..thiscard], .little);
            header.containers[k] = .{
                .pool_offset = pool_offset,
                .n_blocks = @intCast(n_blocks),
                .n_runs = undefined,
                .typecode = .array,
            };
            pool_offset += n_blocks;
        }
    }

    assert(freader.size == null or freader.atEnd());

    const ret = Bitmap{ .header = header, .pool = pool };

    // FIXME - portable_size_in_bytes() doesn't match logicalPos on testdatawithruns - 48056 48050
    // std.debug.print("{} {}\n", .{ freader.logicalPos(), ret.portable_size_in_bytes() });
    assert(true or freader.logicalPos() == ret.portable_size_in_bytes()); // FIXME
    return ret;
}

pub fn add_many(r: *Bitmap, allocator: mem.Allocator, vals: []const u32) !void {
    // std.debug.print("-- add_many() - vals {any} container_count {}\n", .{ vals[0..@min(6, vals.len)], r.header.container_count });

    for (vals) |v| {
        try r.add(allocator, v);
    }
}

pub fn add(r: *Bitmap, allocator: mem.Allocator, v: u32) !void {
    const key: u16, const val: u16 = .{ @truncate(v >> 16), @truncate(v) };
    const mcontaineridx = misc.binarySearch(r.header.get_keys(), key);
    if (mcontaineridx >= 0) { // key found
        const containeridx: u32 = @intCast(mcontaineridx);
        const card = r.header.get_cards()[containeridx];
        const c = r.header.containers[containeridx];
        assert(c.n_blocks <= 256);
        const block_bytes = mem.sliceAsBytes(r.pool.items[c.pool_offset..][0..c.n_blocks]);

        if (c.typecode == .bitset) {
            const wordidx, const idx = .{ v / 64, v % 64 };
            const bitset_values = mem.bytesAsSlice(u64, block_bytes);
            const found = bitset_values[wordidx] & @as(u64, 1) << @intCast(idx) != 0;
            if (!found) {
                bitset_values[wordidx] |= @as(u64, 1) << @intCast(idx);
                r.header.cardinalities[containeridx] += 1;
            }
        } else if (c.typecode == .array) {
            assert(card <= 4096);
            const values = mem.bytesAsSlice(u16, block_bytes);
            const valuesidx = misc.binarySearch(values[0..card], val);
            // std.debug.print("key found card {} found idx {} containers {}\n", .{ card, valuesidx, m });
            if (valuesidx < 0) { // value not found
                if (card == 4096) { // array container full, promote to bitset
                    if (c.pool_offset + c.n_blocks == r.pool.items.len) { // last block, append/overwrite ok
                        const pool_offset = r.pool.items.len;
                        const bblocks = try r.pool.addManyAsSlice(allocator, C.BITSET_BLOCKS);
                        @memset(bblocks, @splat(0));
                        const bvalues = mem.bytesAsSlice(u64, mem.sliceAsBytes(bblocks));
                        const abytes = mem.sliceAsBytes(r.pool.items[c.pool_offset..][0..c.n_blocks]); // avoids stale `values` pointer
                        for (mem.bytesAsSlice(u16, abytes)) |arrval| {
                            const wordidx, const idx = .{ arrval / 64, arrval % 64 };
                            bvalues[wordidx] |= @as(u64, 1) << @intCast(idx);
                        }
                        const wordidx, const idx = .{ v / 64, v % 64 };
                        bvalues[wordidx] |= @as(u64, 1) << @intCast(idx);
                        r.header.cardinalities[containeridx] = 4097;
                        r.header.containers[containeridx] = .{
                            .typecode = .bitset,
                            .n_blocks = C.BITSET_BLOCKS,
                            .pool_offset = c.pool_offset,
                            .n_runs = undefined,
                        };
                        // std.debug.print("c (po {} nb {}) new pool_offset {} {}\n", .{ c.pool_offset, c.n_blocks, pool_offset, C.BITSET_BLOCKS });
                        @memcpy( // replace array blocks with bitset blocks
                            r.pool.items[c.pool_offset..][0..C.BITSET_BLOCKS],
                            r.pool.items[pool_offset..][0..C.BITSET_BLOCKS],
                        );
                        r.pool.items.len = c.pool_offset + C.BITSET_BLOCKS; // shrink len
                    } else { // move contaier blocks
                        unreachable; // TODO
                    }
                } else if (card < @as(u32, c.n_blocks) * C.BLOCK_LEN16) { // room in block
                    // std.debug.print("card {} {any}\n", .{ card, values });
                    values[@intCast(-valuesidx - 1)] = val;
                    r.header.get_cards()[containeridx] += 1;
                } else { // container blocks full, add new block
                    if (c.pool_offset + c.n_blocks == r.pool.items.len) { // last block, append ok
                        // std.debug.print("adding block to container {} of blocks {}...{}\n", .{ key, m.pool_offset, m.pool_offset + m.n_blocks });
                        _ = try r.pool.addOne(allocator);
                        const nblocks = r.pool.items[c.pool_offset..][0 .. c.n_blocks + 1];
                        const nblock_bytes = mem.sliceAsBytes(nblocks);
                        const nvalues = mem.bytesAsSlice(u16, nblock_bytes);
                        nvalues[@intCast(-valuesidx - 1)] = val;
                        r.header.get_cards()[containeridx] += 1;
                        r.header.get_containers()[containeridx].n_blocks += 1;
                    } else { // move contaier blocks
                        unreachable; // TODO
                    }
                }
            }
        }
    } else { // key not found, add new array container
        const j: u32 = @intCast(-mcontaineridx - 1);
        // std.debug.print("insert_value() - new container - j {} v {} container_count {}\n", .{ j, v, r.header.container_count });

        const buf_size = Header.buffer_size_from_magic_count(r.header.magic, r.header.container_count + 1);
        const buf = try allocator.alloc(u8, buf_size);
        errdefer allocator.free(buf);
        var fba = std.heap.FixedBufferAllocator.init(buf);
        const fbaa = fba.allocator();
        var newh = r.header;
        newh.container_count += 1;
        newh.n_blocks += 1;
        // std.debug.print("h.container_count {} newh.container_count {}\n", .{ r.header.container_count, newh.container_count });
        if (r.header.can_have_run_containers()) { // copy run flags
            const l = (newh.container_count + 7) / 8;
            newh.run_flags = (try fbaa.alloc(u8, l)).ptr;
            std.debug.print("old run flags {any}\n", .{r.header.get_run_flags()});
            std.debug.print("new run flags {any}\n", .{newh.get_run_flags()});
            unreachable; // TODO
        }

        // alloc/copy new keys, cards, containers
        const newkeys = try fbaa.alloc(u16, newh.container_count);
        @memcpy(newkeys.ptr, r.header.keys[0..j]);
        newkeys[j] = key;
        @memcpy(newkeys.ptr + j + 1, r.header.keys[j..r.header.container_count]);
        // std.debug.print("newkeys {any}\n", .{newkeys});
        newh.keys = newkeys.ptr;

        newh.cardinalities = (try fbaa.alloc(u32, newh.container_count)).ptr;
        @memcpy(newh.cardinalities, r.header.cardinalities[0..j]);
        newh.cardinalities[j] = 1;
        @memcpy(newh.cardinalities + j + 1, r.header.cardinalities[j..r.header.container_count]);

        newh.containers = (try fbaa.alloc(Container, newh.container_count)).ptr;
        @memcpy(newh.containers, r.header.containers[0..j]);
        newh.containers[j] = .{
            .n_runs = undefined,
            .pool_offset = @intCast(r.pool.items.len),
            .n_blocks = 1,
            .typecode = .array,
        };
        @memcpy(newh.containers + j + 1, r.header.containers[j..r.header.container_count]);

        const block = try r.pool.addOne(allocator);
        const block_bytes = mem.asBytes(block);
        const values = mem.bytesAsSlice(u16, block_bytes);
        values[0] = val;
        // std.debug.print("newh {}\n", .{newh.*});
        // std.debug.print("newh keys {any}\n", .{newh.get_keys()});
        r.header.deinit(allocator);
        r.header = newh;
    }
}

///
/// Add all values in range [min, max]
pub fn add_range_closed(r: *Bitmap, allocator: mem.Allocator, min: u32, max: u32) !void {
    _ = allocator; // autofix
    // std.debug.print("add_range_closed({},{})\n", .{ min, max });
    if (min > max) return;
    const min_key = min >> 16;
    const max_key = max >> 16;

    const num_required_containers = max_key - min_key + 1;
    const h = r.header orelse unreachable;
    const suffix_length = misc.count_greater(h.get_keys(), @truncate(max_key));
    const prefix_length = misc.count_less(
        h.get_keys()[0 .. h.container_count - suffix_length],
        @truncate(min_key),
    );
    const common_length = h.container_count - prefix_length - suffix_length;

    // std.debug.print("num_required_containers {}, common_length {}, {f}\n", .{ num_required_containers, common_length, ra });
    if (num_required_containers > common_length) {
        unreachable; // TODO
        // try ra.shift_tail(
        //     allocator,
        //     suffix_length,
        //     @intCast(num_required_containers -% common_length),
        // );
    }

    var src = misc.cast(i32, prefix_length + common_length) - 1;
    var dst = misc.cast(i32, h.container_count - suffix_length) - 1;
    var key = max_key;
    while (key != min_key -% 1) : (key -%= 1) { // beware of min_key==0
        // std.debug.print("key {} min_key {} max_key {}\n", .{ key, min_key, max_key });
        const container_min = if (min_key == key) min & 0xffff else 0;
        _ = container_min; // autofix
        const container_max = if (max_key == key) max & 0xffff else 0xffff;
        _ = container_max; // autofix
        // std.debug.print("src {}\n", .{src});
        if (src >= 0 and h.get_keys()[@intCast(src)] == key) {
            const srcu: u16 = @intCast(src);
            _ = srcu; // autofix
            // ra.unshare_container_at_index(srcu);
            // new_container =
            //     try s.items(.container)[srcu].add_range(allocator, container_min, container_max);
            // if (new_container != s.items(.container)[srcu]) {
            //     s.items(.container)[srcu].deinit(allocator);
            // }
            src -= 1;
            unreachable; // TODO
        } else {
            // new_container = try .from_range(allocator, container_min, container_max + 1, 1);
            unreachable; // TODO
        }
        // std.debug.print("dst {}, new_container {f}\n", .{ dst, new_container });
        // assert(!new_container.is_empty());
        // ra.replace_key_and_container_at_index(@intCast(dst), @truncate(key), new_container);
        dst -= 1;
        unreachable; // TODO
    }
}

const u32_max = std.math.maxInt(u32);
///
/// Add all values in range [min, max)
pub fn add_range(r: *Bitmap, allocator: mem.Allocator, min: u64, max: u64) !void {
    // std.debug.print("add_range({},{})\n", .{ min, max });
    if (max <= min or min > @as(u64, u32_max) + 1) {
        return;
    }
    try r.add_range_closed(allocator, @intCast(min), @intCast(max - 1));
}

pub fn contains(r: Bitmap, val: u32) bool {
    const h = r.header;
    const key: u16 = @truncate(val >> 16);
    // the next function call involves a binary search and lots of branching.
    const i = misc.binarySearch(h.get_keys(), key);
    // std.debug.print("Bitmap.contains({}) key {} i {}\n", .{ val, key, i });
    if (i < 0) return false;
    const iu: u32 = @bitCast(i);

    // rest might be a tad expensive, possibly involving another round of binary search
    const m = h.get_containers()[iu];
    // std.debug.print("{}\n", .{m});
    const card: u32 = h.cardinalities[iu];
    const pos: u16 = @truncate(val);
    switch (m.typecode) {
        .bitset => {
            const word_idx = pos / 64;
            const bit_idx = pos % 64;
            const bitset: *C.Bitset = @ptrCast(&r.pool.items[m.pool_offset]);
            return (bitset[word_idx] & (@as(u64, 1) << @intCast(bit_idx))) != 0;
        },
        .array => {
            const blocks_size = mem.alignForward(u32, card * 2, C.BLOCK_LEN);
            const n_blocks = @divExact(blocks_size, C.BLOCK_LEN);
            const blocks_bytes = mem.sliceAsBytes(r.pool.items[m.pool_offset..][0..n_blocks]);
            const values = mem.bytesAsSlice(u16, blocks_bytes);
            const slice = values[0..card];
            // std.debug.print("slice {any}\n", .{slice});

            // binary search with fallback to linear search for short ranges
            var low: i32 = 0;
            var high = @as(i32, @intCast(card));
            while (high >= low + 16) {
                const middleIndex = (low + high) >> 1;
                const middleValue = slice[@intCast(middleIndex)];
                // std.debug.print("low {} high {} middleIndex {} middlevalue {}\n", .{ low, high, middleIndex, middleValue });
                if (middleValue < pos) {
                    low = middleIndex + 1;
                } else if (middleValue > pos) {
                    high = middleIndex - 1;
                } else {
                    return true;
                }
            }

            var j = low;
            while (j <= high) : (j += 1) {
                const v = slice[@intCast(j)];
                if (v == pos) return true;
                if (v > pos) return false;
            }
            return false;
        },
        .run => {
            const blocks_size = mem.alignForward(u32, @as(u32, m.n_runs) * @sizeOf(root.Rle16), C.BLOCK_LEN);
            const n_blocks = @divExact(blocks_size, C.BLOCK_LEN);
            const blocks_bytes = mem.sliceAsBytes(r.pool.items[m.pool_offset..][0..n_blocks]);
            const run_slice = mem.bytesAsSlice(root.Rle16, blocks_bytes);
            const runs = run_slice[0..m.n_runs];
            var index = misc.interleavedBinarySearch(runs, pos);
            if (index >= 0) return true;
            index = -index - 2; // points to preceding value, possibly -1
            if (index != -1) { // possible match
                const offset = pos - runs[@intCast(index)].value;
                const le = runs[@intCast(index)].length;
                if (offset <= le) return true;
            }
            return false;
        },
        .shared => unreachable,
    }
}

/// true if the two bitmaps contain the same elements.
pub fn equals(r1: Bitmap, r2: Bitmap) bool {
    const h1 = r1.header;
    const h2 = r2.header;
    if (h1.container_count != h2.container_count)
        return false;

    for (h1.get_keys(), h2.get_keys()) |k1, k2| {
        if (k1 != k2) return false;
    }

    for (
        h1.get_cards(),
        h2.get_cards(),
        h1.get_containers(),
        h2.get_containers(),
    ) |card1, card2, c1, c2| {
        if (c1.typecode != c2.typecode or card1 != card2)
            return false;

        const c1bytes = mem.sliceAsBytes(r1.pool.items[c1.pool_offset..][0..c1.n_blocks]);
        const c2bytes = mem.sliceAsBytes(r2.pool.items[c2.pool_offset..][0..c2.n_blocks]);
        if (!switch (c1.typecode) {
            .array => mem.eql(
                u16,
                mem.bytesAsSlice(u16, c1bytes)[0..card1],
                mem.bytesAsSlice(u16, c2bytes)[0..card1],
            ),
            .run => c1.n_runs == c2.n_runs and mem.eql(
                u16,
                mem.bytesAsSlice(u16, c1bytes)[0..c1.n_runs],
                mem.bytesAsSlice(u16, c2bytes)[0..c1.n_runs],
            ),
            .bitset => mem.eql(
                u64,
                mem.bytesAsSlice(u64, c1bytes[0..@sizeOf(C.Bitset)]),
                mem.bytesAsSlice(u64, c2bytes[0..@sizeOf(C.Bitset)]),
            ),
            .shared => unreachable,
        })
            return false;
    }

    return true;
}

///
/// Get the index corresponding to a 16-bit key
///
pub fn get_index(r: Bitmap, v: u32) i32 {
    const key: u16 = @truncate(v >> 16);
    const h = r.header;
    const keys = h.get_keys();
    if (h.container_count == 0 or keys[h.container_count - 1] == key)
        return @as(i32, @intCast(h.container_count)) - 1;
    return misc.binarySearch(keys, key);
}

pub fn has_run_container(r: Bitmap) bool {
    return r.header.has_run_container();
}

pub fn portable_header_size(r: Bitmap) usize {
    return r.header.portable_size();
}

pub fn portable_size_in_bytes(r: Bitmap) usize {
    return r.header.portable_size_in_bytes();
}

/// Writes the container to `w`, returns how many bytes were written.
/// The number of bytes written should be equal to `portable_size_in_bytes()`.
pub fn write(r: Bitmap, c: Container, card: u32, w: *Io.Writer) !usize {
    switch (c.typecode) {
        .array => {
            // std.debug.print("array card {}\n", .{ card });
            const bytes = mem.sliceAsBytes(r.pool.items[c.pool_offset..][0..c.n_blocks]);
            try w.writeSliceEndian(u16, mem.bytesAsSlice(u16, bytes)[0..card], .little);
            return card * 2;
        },
        .run => unreachable,
        .bitset => {
            assert(c.n_blocks == C.BITSET_BLOCKS);
            const bytes = mem.sliceAsBytes(r.pool.items[c.pool_offset..][0..c.n_blocks]);
            try w.writeSliceEndian(u64, mem.bytesAsSlice(u64, bytes), .little);
            return @sizeOf(C.Bitset);
        },
        .shared => unreachable,
    }
}

pub fn portable_serialize(r: Bitmap, w: *std.Io.Writer, temp_allocator: mem.Allocator) !usize {
    const h = r.header;
    const cslen = h.container_count;
    if (cslen == 0) {
        try w.writeStruct(root.Cookie{
            .magic = .SERIAL_COOKIE_NO_RUNCONTAINER,
            .cardinality_minus1 = 0,
        }, .little);
        try w.writeInt(u32, 0, .little);
        return @sizeOf(u32) * 2;
    }

    var startOffset: u32 = 0;
    var written_count: usize = 0;
    const hasrun = r.has_run_container();
    const cs = h.get_containers();
    if (hasrun) {
        try w.writeStruct(root.Cookie{
            .magic = .SERIAL_COOKIE,
            .cardinality_minus1 = @intCast(cslen - 1),
        }, .little);
        written_count += @sizeOf(root.Cookie);
        const s = (cslen + 7) / 8;
        const buf = try temp_allocator.alloc(u8, s);
        @memset(buf, 0);
        for (cs, 0..) |c, i| {
            if (c.typecode == .run) {
                buf[i / 8] |= @as(u8, 1) << @intCast(i % 8);
            }
        }
        try w.writeAll(buf);
        written_count += s;
        startOffset = if (cslen < C.NO_OFFSET_THRESHOLD)
            4 + 4 * cslen + s
        else
            4 + 8 * cslen + s;
    } else { // backwards compatibility
        try w.writeStruct(root.Cookie{
            .magic = .SERIAL_COOKIE_NO_RUNCONTAINER,
            .cardinality_minus1 = 0,
        }, .little);
        try w.writeInt(u32, cslen, .little);
        written_count += @sizeOf(root.Cookie) + @sizeOf(u32);
        startOffset = 4 + 4 + 4 * cslen + 4 * cslen;
    }
    const cards = h.get_cards();
    for (h.get_keys(), cards) |k, card| {
        try w.writeInt(u16, k, .little);
        // get_cardinality returns a value in [1,1<<16], subtracting one
        // we get [0,1<<16 - 1] which fits in 16 bits
        try w.writeInt(u16, @intCast(card - 1), .little);
        written_count += @sizeOf(u16) + @sizeOf(u16);
    }
    if ((!hasrun) or (cslen >= C.NO_OFFSET_THRESHOLD)) {
        // write the containers offsets
        for (cs, cards) |c, card| {
            try w.writeInt(u32, startOffset, .little);
            written_count += @sizeOf(u32);
            startOffset += @intCast(c.size_in_bytes(card));
        }
    }

    for (cs, cards) |c, card| {
        written_count += try r.write(c, card, w);
    }

    return written_count;
}

pub fn set_container_at_index(r: *Bitmap, i: u32, c: Container) void {
    r.header.get_containers()[i] = c;
}

///
/// Convert array and bitmap containers to run containers when it is more
/// efficient; also convert from run containers when more space efficient.
///
/// Returns true if the result has at least one run container.
/// Additional savings might be possible by calling `shrinkToFit()`.
pub fn run_optimize(r: *Bitmap, allocator: mem.Allocator) !bool {
    var answer = false;
    for (r.header.get_containers(), r.header.get_cards(), 0..) |c, card, i| {
        // r.unshare_container_at_index(@intCast(i)); // TODO: this introduces extra cloning!

        const c1 = try r.convert_run_optimize(c, card, allocator);
        if (c1.typecode == .run) answer = true;
        if (c != c1) {
            // std.debug.print("run_optimize. converted {f} to {f}\n", .{ c, c1 });
            r.set_container_at_index(@intCast(i), c1);
        }
    }
    return answer;
}

/// Get the cardinality of the bitmap (number of elements).
pub fn cardinality(r: Bitmap) u64 {
    var card: u64 = 0;
    for (r.header.get_cards()) |c| card += c;
    return card;
}
pub const get_cardinality = cardinality;

/// once converted, the original container is disposed here, rather than
/// in roaring_array
///
// TODO: split into run-  array-  and bitset-  subfunctions for sanity;
// a few function calls won't really matter.
pub fn convert_run_optimize(r: *Bitmap, c: Container, card: u32, allocator: mem.Allocator) !Container {
    std.debug.print("convert_run_optimize() {t}\n", .{c.typecode});
    if (c.typecode == .run) {
        const newc = try r.convert_run_to_efficient_container(c, card, allocator);
        _ = newc; // autofix
        // if (newc != c) c.deinit(allocator);
        // return newc;
        unreachable;
    } else if (c.typecode == .array) {
        unreachable;
        // // it might need to be converted to a run container.
        // const c_qua_array = c.const_cast(.array);
        // const n_runs = c_qua_array.number_of_runs();
        // const size_as_run_container = RunContainer.serialized_size_in_bytes(n_runs);
        // const card = c_qua_array.cardinality;
        // const size_as_array_container = ArrayContainer.serialized_size_in_bytes(card);

        // if (size_as_run_container >= size_as_array_container) {
        //     return c;
        // }
        // // else convert array to run container
        // var answer = try RunContainer.init_with_capacity(allocator, n_runs);
        // var prev: i32 = -2;
        // var run_start: i32 = -1;

        // assert(card > 0);
        // var i: u32 = 0;
        // while (i < card) : (i += 1) {
        //     const cur_val = c_qua_array.array[i];
        //     if (cur_val != prev + 1) {
        //         // new run starts; flush old one, if any
        //         if (run_start != -1) answer.add_run(@intCast(run_start), @intCast(prev));
        //         run_start = cur_val;
        //     }
        //     prev = c_qua_array.array[i];
        // }
        // assert(run_start >= 0);
        // // now prev is the last seen value
        // answer.add_run(@intCast(run_start), @intCast(prev));
        // c.deinit(allocator);
        // return .create(allocator, answer);
    } else if (c.typecode == .bitset) { // run conversions on bitset
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
    unreachable;
}

/// Converts a run container to either an array or a bitset, IF it saves space.
///
/// If a conversion occurs, the caller is responsible to free the original
/// container and he becomes responsible to free the new one.
pub fn convert_run_to_efficient_container(r: *Bitmap, c: Container, card: u32, allocator: mem.Allocator) !Container {
    _ = r; // autofix
    _ = allocator; // autofix
    assert(c.typecode == .run);
    const size_as_run_container = c.serialized_size_in_bytes(undefined);

    const size_as_bitset_container = @sizeOf(C.Bitset);

    var ac: Container = undefined;
    ac.typecode = .array;
    const size_as_array_container = ac.serialized_size_in_bytes(card);

    const min_size_non_run =
        if (size_as_bitset_container < size_as_array_container)
            size_as_bitset_container
        else
            size_as_array_container;
    if (size_as_run_container <= min_size_non_run) { // no conversion
        // return try .create(allocator, c.*);
        unreachable; // TODO
    }
    if (card <= C.DEFAULT_MAX_SIZE) {
        unreachable; // TODO
        // // to array
        // var answer = try ArrayContainer.init_with_capacity(allocator, card);
        // answer.cardinality = 0;
        // for (0..c.n_runs) |rlepos| {
        //     const run_start = c.runs[rlepos].value;
        //     const run_end = run_start + c.runs[rlepos].length;

        //     var run_value = run_start;
        //     while (run_value < run_end) : (run_value += 1) {
        //         answer.array[answer.cardinality] = run_value;
        //         answer.cardinality += 1;
        //     }
        // }

        // return .create(allocator, answer);
    }
    unreachable; // TODO
    // // else to bitset
    // var answer = try BitsetContainer.create(allocator);

    // for (0..c.n_runs) |rlepos| {
    //     const start = c.runs[rlepos].value;
    //     const end = start + c.runs[rlepos].length;
    //     BitsetContainer.set_range(answer.words, start, end + 1);
    // }
    // answer.cardinality = card;
    // return .create(allocator, answer);
}

fn deserializeTestdataPortable(io: Io, f: Io.File) !Bitmap {
    var rbuf: [256]u8 = undefined;
    return try portable_deserialize(testing.allocator, io, f, &rbuf);
}

fn validateTestdataFile(rb: Bitmap) !void {
    // > They contain all multiplies of 1000 in [0,100000), all multiplies of 3 in [100000,200000) and all values in [700000,800000).
    // > https://github.com/RoaringBitmap/RoaringFormatSpec/tree/master/testdata
    var k: u32 = 0;
    while (k < 100000) : (k += 1000) {
        try testing.expect(rb.contains(k));
    }
    k = 100000;
    while (k < 200000) : (k += 1) {
        try testing.expect(rb.contains(3 * k));
    }
    k = 700000;
    while (k < 800000) : (k += 1) {
        try testing.expect(rb.contains(k));
    }
}

test Bitmap {
    const io = testing.io;
    { // "without runs"
        const filepath = "testdata/bitmapwithoutruns.bin";
        const f = try Io.Dir.cwd().openFile(io, filepath, .{});
        defer f.close(io);
        var rb = try deserializeTestdataPortable(io, f);
        defer rb.deinit(testing.allocator);
        try testing.expectEqual(.SERIAL_COOKIE_NO_RUNCONTAINER, rb.header.magic);
        try testing.expectEqual(8 * 256 + 220, rb.pool.items.len); // 8 bitsets, 220 array blocks
        try validateTestdataFile(rb);
    }
    { // "with runs"
        const filepath = "testdata/bitmapwithruns.bin";
        const f = try Io.Dir.cwd().openFile(io, filepath, .{});
        defer f.close(io);
        var rb = try deserializeTestdataPortable(io, f);
        defer rb.deinit(testing.allocator);
        try testing.expectEqual(.SERIAL_COOKIE, rb.header.magic);
        try testing.expectEqual(5 * 256 + 220 + 3, rb.pool.items.len); // 5 bitsets, 220 array blocks, 3 run blocks
        try validateTestdataFile(rb);
    }
}

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;
const Io = std.Io;
const builtin = @import("builtin");
const C = @import("constants.zig");
const misc = @import("misc.zig");
const root = @import("root.zig");
