pub const DEFAULT_MAX_SIZE = 4096; // MAX_CONTAINERS / 16
pub const MAX_CONTAINERS = 65536; // DEFAULT_MAX_SIZE * 16
/// max key cardinality
pub const MAX_CARDINALITY = MAX_CONTAINERS;

pub const SERIALIZATION_ARRAY_UINT32 = 1;
pub const SERIALIZATION_CONTAINER = 2;
pub const NO_OFFSET_THRESHOLD = 4;
pub const BITSET_UNKNOWN_CARDINALITY = 0xffff_ffff;

comptime {
    assert(DEFAULT_MAX_SIZE == @divExact(MAX_CONTAINERS, 16));
    assert(MAX_CONTAINERS == 1 << 16);
}

pub const BLOCK_LEN = std.simd.suggestVectorLength(u8).?; // 32
pub const Block = @Vector(BLOCK_LEN, u8);
pub const BLOCK_ALIGN = @alignOf(Block);
pub const BLOCK_ALIGNMENT: std.mem.Alignment = .fromByteUnits(BLOCK_ALIGN);
pub const Bitset = [1024]u64;
pub const BITSET_BLOCKS = @divExact(@sizeOf(Bitset), @sizeOf(Block)); // 256
pub const BLOCK_LEN16 = @divExact(BLOCK_LEN, 2); // 16

const std = @import("std");
const assert = std.debug.assert;
const root = @import("root.zig");
