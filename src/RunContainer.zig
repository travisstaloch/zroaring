const RunContainer = @This();

runs: [*]Rle16,
n_runs: u32,
capacity: u32,

pub const Rle16 = struct { value: u16, length: u16 };

pub const init: RunContainer = .{ .runs = undefined, .n_runs = 0, .capacity = 0 };
pub fn init_with_capacity(allocator: mem.Allocator, size: u32) !RunContainer {
    return .{ .runs = (try allocator.alloc(Rle16, size)).ptr, .capacity = size, .n_runs = 0 };
}
///
/// The new container consists of a single run [start,stop).
/// It is required that stop>start, the caller is responsability for this check.
/// It is required that stop <= (1<<16), the caller is responsability for this
/// check. The cardinality of the created container is stop - start. Returns NULL
/// on failure
///
pub fn init_range(allocator: mem.Allocator, start: u32, stop: u32) !RunContainer {
    var rc = try init_with_capacity(allocator, 1);
    _ = rc.append_first(.{ .value = @truncate(start), .length = @truncate(stop - start - 1) });
    return rc;
}
pub fn deinit(r: RunContainer, allocator: mem.Allocator) void {
    allocator.free(r.runs[0..r.capacity]);
}
///
/// Like run_container_append but it is assumed that the content of run is empty.
///
pub fn append_first(run: *RunContainer, vl: Rle16) Rle16 {
    run.runs[run.n_runs] = vl;
    run.n_runs += 1;
    return vl;
}
///
/// Effectively deletes the value at index index, repacking data.
///
fn recoverRoomAtIndex(run: *RunContainer, index: u16) void {
    @memmove(
        run.runs + index,
        (run.runs + (1 + index))[0 .. run.n_runs - index - 1],
    );
    run.n_runs -= 1;
}

/// returns a bool indicating whether the value was added
pub fn add(run: *RunContainer, allocator: mem.Allocator, pos: u16) !bool {
    var index = misc.interleavedBinarySearch(run.slice(), pos);
    if (index >= 0) return false;
    index = -index - 2; // points to preceding value, possibly -1
    if (index >= 0) { // possible match
        const indexu: u32 = @intCast(index);

        const offset = pos - run.runs[indexu].value;
        const le = run.runs[indexu].length;
        if (offset <= le) return false; // already there
        if (offset == le + 1) {
            // we may need to fuse
            if (indexu + 1 < run.n_runs) {
                if (run.runs[indexu + 1].value == pos + 1) {
                    // indeed fusion is needed
                    run.runs[indexu].length = run.runs[indexu + 1].value +
                        run.runs[indexu + 1].length -
                        run.runs[indexu].value;
                    run.recoverRoomAtIndex(@intCast(indexu + 1));
                    return true;
                }
            }
            run.runs[indexu].length += 1;
            return true;
        }
        if (indexu + 1 < run.n_runs) {
            // we may need to fuse
            if (run.runs[indexu + 1].value == pos + 1) {
                // indeed fusion is needed
                run.runs[indexu + 1].value = pos;
                run.runs[indexu + 1].length = run.runs[indexu + 1].length + 1;
                return true;
            }
        }
    }
    if (index == -1) {
        // we may need to extend the first run
        if (run.n_runs > 0) {
            if (run.runs[0].value == pos + 1) {
                run.runs[0].length = 1;
                run.runs[0].value -= 1;
                return true;
            }
        }
    }
    try run.makeRoomAtIndex(allocator, @truncate(index + 1));
    run.runs[@intCast(index + 1)].value = pos;
    run.runs[@intCast(index + 1)].length = 0;
    return true;
}

pub fn serialized_size_in_bytes(n_runs: u32) usize {
    return @sizeOf(u16) + @sizeOf(Rle16) * n_runs; // each run requires 2 2-byte entries.
}
pub fn size_in_bytes(r: RunContainer) usize {
    return serialized_size_in_bytes(r.n_runs);
}
pub fn write(container: RunContainer, w: *Io.Writer) !usize {
    try w.writeInt(u16, @intCast(container.n_runs), .little);
    try w.writeSliceEndian(Rle16, container.slice(), .little);
    return container.size_in_bytes();
}
pub fn contains(r: RunContainer, pos: u16) bool {
    var index = misc.interleavedBinarySearch(r.slice(), pos);
    // std.debug.print("RunContainer.contains pos {} index {}\n", .{pos, index});
    if (index >= 0) return true;
    index = -index - 2; // points to preceding value, possibly -1
    if (index != -1) { // possible match
        const offset = pos - r.runs[@intCast(index)].value;
        const le = r.runs[@intCast(index)].length;
        if (offset <= le) return true;
    }
    return false;
}
pub fn read(r: *RunContainer, allocator: mem.Allocator, n_runs: u32, ior: *Io.Reader) !usize {
    if (n_runs > r.capacity) {
        try r.grow(allocator, n_runs, false);
    }
    r.n_runs = n_runs;
    // std.debug.print("RunContainer.read() r {any}\n", .{r});
    try ior.readSliceEndian(Rle16, r.slice(), .little);
    return r.size_in_bytes();
}
pub fn grow(r: *RunContainer, allocator: mem.Allocator, min: u32, copy: bool) !void {
    var newCapacity = if (r.capacity == 0)
        0
    else if (r.capacity < 64)
        r.capacity * 2
    else if (r.capacity < 1024)
        r.capacity * 3 / 2
    else
        r.capacity * 5 / 4;
    if (newCapacity < min) newCapacity = min;
    // std.debug.print("RunContainer.grow({}) newCapacity {}\n", .{ min, newCapacity });
    r.capacity = newCapacity;
    assert(r.capacity >= min);
    if (copy) {
        const oldruns = r.slice();
        r.runs = (try allocator.realloc(oldruns, r.capacity)).ptr;
    } else {
        allocator.free(r.slice());
        r.runs = (try allocator.alloc(Rle16, r.capacity)).ptr;
    }
}
pub fn slice(c: RunContainer) []Rle16 {
    return c.runs[0..c.n_runs];
}
/// Get the cardinality of `run'. Requires an actual computation.
pub fn get_cardinality_scalar(run: RunContainer) u64 {
    var sum = run.n_runs; // start at n_runs to skip +1 for each pair.
    for (0..run.n_runs) |k| sum += run.runs[k].length;
    return sum;
}
///
/// Moves the data so that we can write data at index
///
fn makeRoomAtIndex(run: *RunContainer, allocator: mem.Allocator, index: u0) !void {
    // static inline void makeRoomAtIndex(run_container_t *run, uint16_t index) {
    // This function calls realloc + memmove sequentially to move by one index.
    // Potentially copying twice the array.
    //
    if (run.n_runs + 1 > run.capacity)
        try run.grow(allocator, run.n_runs + 1, true);
    const len = run.n_runs - index;
    @memmove(
        (run.runs + 1 + index)[0..len],
        (run.runs + index)[0..len],
    );
    run.n_runs += 1;
}

///
/// Add all values in range [min, max] using hint.
///
pub fn add_range_nruns(run: *RunContainer, allocator: mem.Allocator, min: u32, max: u32, nruns_less: u32, nruns_greater: u32) !void {
    const nruns_common = run.n_runs - nruns_less - nruns_greater;
    if (nruns_common == 0) {
        try run.makeRoomAtIndex(allocator, @truncate(nruns_less));
        run.runs[nruns_less].value = @truncate(min);
        run.runs[nruns_less].length = @truncate(max - min);
    } else {
        const common_min = run.runs[nruns_less].value;
        const common_max = run.runs[nruns_less + nruns_common - 1].value +
            run.runs[nruns_less + nruns_common - 1].length;
        const result_min = @min(common_min, min);
        const result_max = @max(common_max, max);

        run.runs[nruns_less].value = @truncate(result_min);
        run.runs[nruns_less].length = @truncate(result_max - result_min);

        @memmove(
            run.runs[nruns_less + 1 ..][0..nruns_greater],
            run.runs[run.n_runs - nruns_greater ..][0..nruns_greater],
        );
        run.n_runs = nruns_less + 1 + nruns_greater;
    }
}

/// Get the cardinality of `run'. Requires an actual computation.
pub fn cardinality(run: RunContainer) u32 {
    const n_runs = run.n_runs;
    const runs = run.runs;

    // by initializing with n_runs, we omit counting the +1 for each pair.
    var sum = n_runs;
    for (0..n_runs) |k| {
        sum += runs[k].length;
    }

    return sum;
}

/// Converts a run container to either an array or a bitset, IF it saves space.
///
/// If a conversion occurs, the caller is responsible to free the original
/// container and he becomes responsible to free the new one.
pub fn convert_run_to_efficient_container(c: *const RunContainer, allocator: mem.Allocator) !Container {
    const size_as_run_container = RunContainer.serialized_size_in_bytes(c.n_runs);

    const size_as_bitset_container = BitsetContainer.serialized_size_in_bytes();

    const card = c.cardinality();
    const size_as_array_container = ArrayContainer.serialized_size_in_bytes(card);

    const min_size_non_run =
        if (size_as_bitset_container < size_as_array_container)
            size_as_bitset_container
        else
            size_as_array_container;
    if (size_as_run_container <= min_size_non_run) { // no conversion
        return .init(c);
    }
    if (card <= C.DEFAULT_MAX_SIZE) {
        // to array
        var answer = try ArrayContainer.init_with_capacity(allocator, card);
        answer.cardinality = 0;
        for (0..c.n_runs) |rlepos| {
            const run_start = c.runs[rlepos].value;
            const run_end = run_start + c.runs[rlepos].length;

            var run_value = run_start;
            while (run_value < run_end) : (run_value += 1) {
                answer.array[answer.cardinality] = run_value;
                answer.cardinality += 1;
            }
        }

        return .create_from_value(allocator, answer);
    }

    // else to bitset
    var answer = try BitsetContainer.create(allocator);

    for (0..c.n_runs) |rlepos| {
        const start = c.runs[rlepos].value;
        const end = start + c.runs[rlepos].length;
        BitsetContainer.set_range(answer.words, start, end + 1);
    }
    answer.cardinality = card;
    return try .create_from_value(allocator, answer);
}

/// assumes that container has adequate space.  Run from [s,e] (inclusive)
pub fn add_run(c: *RunContainer, s: u32, e: u32) void {
    c.runs[c.n_runs].value = @intCast(s);
    c.runs[c.n_runs].length = @intCast(e - s);
    c.n_runs += 1;
}

///
/// Return true if the two containers have the same content.
///
pub fn equals(container1: RunContainer, container2: *const RunContainer) bool {
    return std.mem.eql(
        u8,
        mem.sliceAsBytes(container1.slice()),
        mem.sliceAsBytes(container2.slice()),
    );
}

pub fn validate(rc: *const RunContainer, reason: *?[]const u8) bool {
    _ = rc; // autofix
    _ = reason; // autofix
    unreachable;
}

pub fn format(c: RunContainer, w: *Io.Writer) !void {
    try w.print("n_runs {}", .{c.n_runs});
}

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Io = std.Io;
const misc = @import("misc.zig");
const root = @import("root.zig");
const Container = root.Container;
const BitsetContainer = root.BitsetContainer;
const ArrayContainer = root.ArrayContainer;
const C = @import("constants.zig");
