pub const DEFAULT_MAX_SIZE = 4096; // MAX_CONTAINERS / 16
pub const MAX_KEY_CARDINALITY = 65536; // DEFAULT_MAX_SIZE * 16
pub const MAX_VALUE_CARDINALITY = MAX_KEY_CARDINALITY * MAX_KEY_CARDINALITY;

pub const SERIALIZATION_ARRAY_UINT32 = 1;
pub const SERIALIZATION_CONTAINER = 2;
pub const NO_OFFSET_THRESHOLD = 4;
pub const BITSET_UNKNOWN_CARDINALITY = MAX_VALUE_CARDINALITY - 1; // 0xffff_ffff

comptime {
    assert(DEFAULT_MAX_SIZE == @divExact(MAX_KEY_CARDINALITY, 16));
    assert(MAX_KEY_CARDINALITY == 1 << 16);
}

pub const BLOCK_LEN = std.simd.suggestVectorLength(u8).?; // 32 bytes / 256 bits with avx2
pub const BLOCK_ALIGN = @alignOf(root.Block);
pub const BLOCK_ALIGNMENT: std.mem.Alignment = .fromByteUnits(BLOCK_ALIGN);
pub const BITSET_BLOCKS = @divExact(@sizeOf(root.Bitset), @sizeOf(root.Block)); // 256
pub const BLOCK_LEN16 = @divExact(BLOCK_LEN, 2); // 16 bytes

const std = @import("std");
const assert = std.debug.assert;
const root = @import("root.zig");
