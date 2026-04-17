const Bitmap = @This();

header: ?*Header = null,
pool: std.ArrayList(C.Block) = .empty,

/// Designed for frequent updates.
/// Fields are ordered by decreasing alignment to reduce size.
/// Allocated as a single allocation with run_flags, keys, cards, metadata
/// immediately following Header bytes.
const Header = extern struct {
    /// insert staging
    insert_buffer: C.InsertBuffer,
    /// of length `(container_count+7)/8` when runs are present, otherwise 0.
    run_flags: [*]u8,
    /// keys from `descriptive_header`.  of length `container_count`.
    keys: [*]u16,
    /// cardinalities from `descriptive_header` + 1.  of length `container_count`.
    cardinalities: [*]u32,
    /// of length `container_count`.
    metadata: [*]ContainerMetadata,
    /// file position where header data ends and container data starts
    container_startpos: u64, // TODO remove, calc when needed
    container_count: u32,
    /// number of SIMD-register sized blocks in the pool.
    n_blocks: u32,
    magic: root.Magic,
    /// u32 x BLOCK_LEN32 bulk insert buffer where inserts are staged before merging
    insert_buffer_len: u8,

    pub const empty = mem.zeroInit(Header, .{
        .run_flags = undefined,
        .keys = undefined,
        .cardinalities = undefined,
        .metadata = undefined,
        .insert_buffer = undefined,
    });

    pub const ALIGNMENT: mem.Alignment = .fromByteUnits(@alignOf(Header));

    pub fn deinit(h: *Header, allocator: mem.Allocator) void {
        var buf: []align(@alignOf(Header)) u8 = mem.asBytes(h);
        // std.debug.print("buf.len {} {*}\n", .{ buf.len, buf.ptr });
        buf.len += h.buffer_size() - @sizeOf(Header);
        // std.debug.print("buf.len {}\n", .{buf.len});

        allocator.free(buf);
    }

    pub fn has_runs(h: Header) bool {
        return h.magic == .SERIAL_COOKIE;
    }

    pub fn get_run_flags(h: Header) []u8 {
        return if (h.has_runs())
            h.run_flags[0 .. (h.container_count + 7) / 8]
        else
            &.{};
    }

    pub fn get_keys(h: Header) []u16 {
        return h.keys[0..h.container_count];
    }

    pub fn get_cards(h: Header) []u32 {
        return h.cardinalities[0..h.container_count];
    }

    pub fn get_metadata(h: Header) []ContainerMetadata {
        return h.metadata[0..h.container_count];
    }

    /// how many bytes are needed to store header slices and the Header -
    /// includes @sizeOf(Header).
    pub fn buffer_size_from_file(io: Io, bitmap_file: Io.File) !Info {
        var read_buf: [32]u8 = undefined;
        var freader = bitmap_file.reader(io, &read_buf);
        return buffer_size_from_file_reader(&freader);
    }

    const Info = struct {
        buffer_size: usize,
        cookie: root.Cookie,
        container_count: u32,
    };

    pub fn buffer_size_from_file_reader(freader: *Io.File.Reader) !Info {
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
        var ret: usize = @sizeOf(Header);
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
        // metadata
        ret = mem.alignForward(usize, ret + @sizeOf(ContainerMetadata) * container_count, @alignOf(ContainerMetadata));
        return ret;
    }

    pub fn buffer_size(h: Header) usize {
        return buffer_size_from_magic_count(h.magic, h.container_count);
    }

    pub fn deserialize(bitmap_file: Io.File, allocator: mem.Allocator, read_buf: []u8) !Header {
        var freader = bitmap_file.reader(read_buf);
        return deserialize_from_file_reader(allocator, &freader);
    }

    pub fn deserialize_from_file_reader(allocator: mem.Allocator, freader: *Io.File.Reader) !*Header {
        const info = try Header.buffer_size_from_file_reader(freader);
        const header_buf = try allocator.alignedAlloc(u8, Header.ALIGNMENT, info.buffer_size);
        const r = &freader.interface;
        errdefer allocator.free(header_buf);
        var fba = std.heap.FixedBufferAllocator.init(header_buf);
        const bufalloc = fba.allocator();

        const ret = try bufalloc.create(Header);
        ret.* = .empty;
        const cookie = info.cookie;
        ret.magic = cookie.magic;
        if (cookie.magic != .SERIAL_COOKIE and
            cookie.magic != .SERIAL_COOKIE_NO_RUNCONTAINER)
            return error.UnexpectedCookie;

        ret.container_count = info.container_count;

        if (ret.container_count > C.MAX_CONTAINERS)
            return error.TooManyContainers; // data must be corrupted

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

        ret.metadata = (try bufalloc.alloc(ContainerMetadata, ret.container_count)).ptr;

        ret.container_startpos = freader.logicalPos();

        for (0..ret.container_count) |k| { // calculate blocks needed to store containers
            const thiscard = ret.cardinalities[k];
            var isbitset = (thiscard > C.DEFAULT_MAX_SIZE);
            var isrun = false;
            if (hasruns and
                ((ret.run_flags[k / 8] & @as(u8, 1) << @truncate(k % 8))) != 0)
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

        assert(freader.atEnd());
        return ret;
    }

    test Header {
        // check Header is as small as if it were an auto layout.
        const header_field_types = comptime blk: {
            const fs = @typeInfo(Header).@"struct".fields;
            var ret: [fs.len]type = undefined;
            for (fs, &ret) |f, *r| r.* = f.type;
            break :blk &ret;
        };
        const HeaderAuto = @Struct(.auto, null, std.meta.fieldNames(Header), header_field_types, &@splat(.{}));
        try testing.expectEqual(@sizeOf(Header), @sizeOf(HeaderAuto));
        const io = testing.io;
        {
            const f = try Io.Dir.cwd().openFile(io, "testdata/bitmapwithoutruns.bin", .{});
            defer f.close(io);
            try testing.expectEqual(248, (try Header.buffer_size_from_file(io, f)).buffer_size);
        }
        {
            const f = try Io.Dir.cwd().openFile(io, "testdata/bitmapwithruns.bin", .{});
            defer f.close(io);
            try testing.expectEqual(248, (try Header.buffer_size_from_file(io, f)).buffer_size);
        }
    }
};

/// Allocates and returns Data as a single allocation read from
/// `bitmap_file` which must be a seekable file.
/// `read_buf` is a temporary buffer.
/// `header_buf` is a temporary buffer with size at least `Header.buffer_size()`.
/// TODO non-seekable files.
pub fn deserialize(
    allocator: mem.Allocator,
    io: Io,
    bitmap_file: Io.File,
    read_buf: []u8,
    // header_buf: []u8,
) !Bitmap {
    var freader = bitmap_file.reader(io, read_buf);
    assert(freader.logicalPos() == 0);
    const header = try Header.deserialize_from_file_reader(allocator, &freader);

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
        if (header.has_runs() and
            ((header.run_flags[k / 8] & @as(u8, 1) << @truncate(k % 8))) != 0)
        {
            isbitset = false;
            isrun = true;
        }
        if (isbitset) {
            try r.readSliceAll(mem.asBytes(pool.items[pool_offset..][0..C.BITSET_BLOCKS]));
            header.metadata[k] = .{
                .pool_offset = pool_offset,
                .n_blocks = C.BITSET_BLOCKS,
                .n_runs = undefined,
                .tag = .bitset,
            };
            pool_offset += C.BITSET_BLOCKS;
        } else if (isrun) {
            const n_runs = try r.takeInt(u16, .little);
            const blocks_size = mem.alignForward(u32, n_runs * 4, C.BLOCK_LEN);
            const n_blocks = @divExact(blocks_size, C.BLOCK_LEN);
            const blocks_bytes = mem.sliceAsBytes(pool.items[pool_offset..][0..n_blocks]);
            const run_slice = mem.bytesAsSlice(root.Rle16, blocks_bytes);
            try r.readSliceEndian(root.Rle16, run_slice[0..n_runs], .little);
            header.metadata[k] = .{
                .pool_offset = pool_offset,
                .n_blocks = @intCast(n_blocks),
                .n_runs = n_runs,
                .tag = .run,
            };
            pool_offset += n_blocks;
        } else {
            const blocks_size = mem.alignForward(u32, thiscard * 2, C.BLOCK_LEN);
            const n_blocks = @divExact(blocks_size, C.BLOCK_LEN);
            const blocks_bytes = mem.sliceAsBytes(pool.items[pool_offset..]);
            const values = mem.bytesAsSlice(u16, blocks_bytes);
            try r.readSliceEndian(u16, values[0..thiscard], .little);
            header.metadata[k] = .{
                .pool_offset = pool_offset,
                .n_blocks = @intCast(n_blocks),
                .n_runs = undefined,
                .tag = .array,
            };
            pool_offset += n_blocks;
        }
    }

    assert(freader.atEnd());

    return .{ .header = header, .pool = pool };
}

pub fn deinit(r: *Bitmap, allocator: mem.Allocator) void {
    r.pool.deinit(allocator);
    if (r.header) |h| h.deinit(allocator);
}

pub fn add_many(r: *Bitmap, allocator: mem.Allocator, vals: []const u32) !void {
    // std.debug.print("-- add_many - vals.len {}\n", .{vals.len});
    if (vals.len == 0) return;
    if (r.header == null) {
        r.header = try allocator.create(Header);
        r.header.?.* = .empty;
    }
    const end = vals.ptr + vals.len;
    var cur = vals.ptr;
    while (@intFromPtr(cur) < @intFromPtr(end)) {
        if (r.header.?.insert_buffer_len < C.BLOCK_LEN32) {
            const h = r.header.?;
            const len = @min(C.BLOCK_LEN32, end - cur + 1);
            // std.debug.print("adding {} vals to insert_buffer\n", .{len});
            @memcpy(h.insert_buffer[h.insert_buffer_len..][0..len], cur[0..len]);
            h.insert_buffer_len += @intCast(len);
            cur += len;
        } else {
            // std.debug.print("merging {} vals from insert_buffer\n", .{r.header.?.insert_buffer_len});

            var insert_buffer_idx: u8 = 0;
            while (insert_buffer_idx < r.header.?.insert_buffer_len) : (insert_buffer_idx += 1) {
                const h = r.header.?;
                const v = r.header.?.insert_buffer[insert_buffer_idx];
                // std.debug.print("{} {} {}\n", .{ h.insert_buffer_len, end - cur, v });
                const key: u16, const val: u16 = .{ @truncate(v >> 16), @truncate(v) };
                const containeridx = misc.binarySearch(h.get_keys(), key);
                if (containeridx >= 0) { // key found
                    const j: u32 = @intCast(containeridx);
                    const card = h.get_cards()[j];
                    const m = h.metadata[j];
                    const blocks = r.pool.items[m.pool_offset..][0..m.n_blocks];
                    const block_bytes = mem.sliceAsBytes(blocks);
                    const values = mem.bytesAsSlice(u16, block_bytes);
                    const valuesidx = misc.binarySearch(values[0..card], val);
                    // std.debug.print("key found card {} found idx {} metadata {}\n", .{ card, valuesidx, m });
                    if (valuesidx < 0) { // value not found
                        if (card <= m.n_blocks * C.BLOCK_LEN32) { // room in block
                            values[@intCast(-valuesidx - 1)] = val;
                            h.get_cards()[j] += 1;
                        } else { // container blocks full, add new block
                            if (m.pool_offset + m.n_blocks == r.pool.items.len) { // last block, append ok
                                // std.debug.print("adding block to container {} of blocks {}...{}\n", .{ key, m.pool_offset, m.pool_offset + m.n_blocks });
                                _ = try r.pool.addOne(allocator);
                                const nblocks = r.pool.items[m.pool_offset..][0..m.n_blocks];
                                const nblock_bytes = mem.sliceAsBytes(nblocks);
                                const nvalues = mem.bytesAsSlice(u16, nblock_bytes);
                                nvalues[@intCast(-valuesidx - 1)] = val;
                                h.get_cards()[j] += 1;
                                h.get_metadata()[j].n_blocks += 1;
                            } else { // move contaier blocks
                                // std.debug.print("{}..{} {}\n", .{ m.pool_offset, m.pool_offset + m.n_blocks, r.pool.items.len });
                                unreachable; // TODO
                            }
                        }
                    }
                } else { // key not found, add new container
                    const j: u32 = @intCast(-containeridx - 1);
                    // std.debug.print("add_many - new container - j {} v {} key {} val {}\n", .{ j, v, key, val });

                    const buf_size = Header.buffer_size_from_magic_count(h.magic, h.container_count + 1);
                    const buf = try allocator.alignedAlloc(u8, Header.ALIGNMENT, buf_size);
                    errdefer allocator.free(buf);
                    var fba = std.heap.FixedBufferAllocator.init(buf);
                    const fbaa = fba.allocator();
                    const newh = try fbaa.create(Header);
                    newh.* = h.*;
                    newh.container_count += 1;
                    newh.n_blocks += 1;
                    if (h.has_runs()) {
                        const l = (newh.container_count + 7) / 8;
                        newh.run_flags = (try fbaa.alloc(u8, l)).ptr;
                        std.debug.print("old run flags {any}\n", .{h.get_run_flags()});
                        std.debug.print("new run flags {any}\n", .{newh.get_run_flags()});
                        unreachable; // TODO copy run flags

                    }
                    // alloc/copy new keys, cards, metadata
                    newh.keys = (try fbaa.alloc(u16, newh.container_count)).ptr;
                    @memcpy(newh.keys, h.keys[0..j]);
                    newh.keys[j] = key;
                    @memcpy(newh.keys + j + 1, h.keys[j..h.container_count]);

                    newh.cardinalities = (try fbaa.alloc(u32, newh.container_count)).ptr;
                    @memcpy(newh.cardinalities, h.cardinalities[0..j]);
                    newh.cardinalities[j] = 1;
                    @memcpy(newh.cardinalities + j + 1, h.cardinalities[j..h.container_count]);

                    newh.metadata = (try fbaa.alloc(ContainerMetadata, newh.container_count)).ptr;
                    @memcpy(newh.metadata, h.metadata[0..j]);
                    newh.metadata[j] = .{
                        .n_runs = undefined,
                        .pool_offset = @intCast(r.pool.items.len),
                        .n_blocks = 1,
                        .tag = .array,
                    };
                    @memcpy(newh.metadata + j + 1, h.metadata[j..h.container_count]);

                    const block = try r.pool.addOne(allocator);
                    const block_bytes = mem.asBytes(block);
                    const values = mem.bytesAsSlice(u16, block_bytes);
                    values[0] = val;
                    // std.debug.print("newh {}\n", .{newh.*});
                    // std.debug.print("newh keys {any}\n", .{newh.get_keys()});
                    h.deinit(allocator);
                    r.header = newh;
                }
            }
            r.header.?.insert_buffer_len = 0;
        }
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
    const h = r.header orelse return false;
    if (h.insert_buffer_len > 0) {
        const x: C.InsertVec = @splat(val);
        const m: C.BlockMask32 = @bitCast(x == h.insert_buffer);
        // std.debug.print("val {} found mask {b} {any}\n", .{ val, m, h.insert_buffer });
        if (m != 0 and @ctz(m) <= h.insert_buffer_len) return true;
    }
    const key: u16 = @truncate(val >> 16);
    // the next function call involves a binary search and lots of branching.
    const i = misc.binarySearch(h.get_keys(), key);
    // std.debug.print("Bitmap.contains({}) key {} i {}\n", .{ val, key, i });
    if (i < 0) return false;
    const iu: u32 = @bitCast(i);

    // rest might be a tad expensive, possibly involving another round of binary search
    const m = h.get_metadata()[iu];
    // std.debug.print("{}\n", .{m});
    const card: u32 = h.cardinalities[iu];
    const pos: u16 = @truncate(val);
    switch (m.tag) {
        .bitset => {
            const word_idx = pos / 64;
            const bit_idx = pos % 64;
            const bitset: *C.Bitset = @ptrCast(&r.pool.items[m.pool_offset]);
            return (bitset[word_idx] & (@as(u64, 1) << @intCast(bit_idx))) != 0;
        },
        .array => {
            const blocks_size = mem.alignForward(u32, @as(u32, card) * 2, C.BLOCK_LEN);
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

///
/// Get the index corresponding to a 16-bit key
///
pub fn get_index(r: Bitmap, v: u32) i32 {
    const key: u16 = @truncate(v >> 16);
    const keys = r.header.?.get_keys();
    if (r.header.?.container_count == 0 or keys[r.header.?.container_count - 1] == key)
        return @as(i32, @intCast(r.header.?.container_count)) - 1;
    return misc.binarySearch(keys, key);
}

pub const KeyCard = extern struct { key: u16, cardinality_minus1: u16 };

const ContainerMetadata = packed struct(u64) {
    /// where the container data starts.  an offset into the data pool.
    pool_offset: u32,
    n_blocks: u14,
    /// only used for runs.  undefined for bitsets and arrays.
    n_runs: u16,
    tag: enum(u2) { shared, bitset, array, run },
};

fn deserializeTestdataPortable(io: Io, f: Io.File) !Bitmap {
    var rbuf: [256]u8 = undefined;
    return try deserialize(testing.allocator, io, f, &rbuf);
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
        try testing.expectEqual(.SERIAL_COOKIE_NO_RUNCONTAINER, rb.header.?.magic);
        try testing.expectEqual(8 * 256 + 220, rb.pool.items.len); // 8 bitsets, 220 array blocks
        try validateTestdataFile(rb);
    }
    { // "with runs"
        const filepath = "testdata/bitmapwithruns.bin";
        const f = try Io.Dir.cwd().openFile(io, filepath, .{});
        defer f.close(io);
        var rb = try deserializeTestdataPortable(io, f);
        defer rb.deinit(testing.allocator);
        try testing.expectEqual(.SERIAL_COOKIE, rb.header.?.magic);
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
