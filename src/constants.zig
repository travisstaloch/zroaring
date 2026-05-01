pub const DEFAULT_MAX_SIZE = 4096; // MAX_CONTAINERS / 16
pub const MAX_KEY_CARDINALITY = 65536; // DEFAULT_MAX_SIZE * 16
pub const MAX_CONTAINERS = MAX_KEY_CARDINALITY;
pub const MAX_VALUE_CARDINALITY = MAX_KEY_CARDINALITY * MAX_KEY_CARDINALITY;

pub const SERIALIZATION_ARRAY_UINT32 = 1;
pub const SERIALIZATION_CONTAINER = 2;
pub const NO_OFFSET_THRESHOLD = 4;
pub const BITSET_UNKNOWN_CARDINALITY = MAX_VALUE_CARDINALITY - 1; // 0xffff_ffff

comptime {
    assert(DEFAULT_MAX_SIZE == @divExact(MAX_KEY_CARDINALITY, 16));
    assert(MAX_KEY_CARDINALITY == 1 << 16);
    assert(BLOCK_BYTES <= @sizeOf(root.Array) and @sizeOf(root.Array) <= 2 * BLOCK_BYTES);
    assert(HEADER_BLOCKS == 1);
}

/// Length in bytes of a Block. Same as `@sizeOf(root.Block)`.
/// 32 bytes / 256 bits w/ avx2.
pub const BLOCK_BYTES = std.simd.suggestVectorLength(u8).?;
pub const BLOCK_ALIGN = @alignOf(root.Block);
pub const BLOCK_ALIGNMENT: std.mem.Alignment = .fromByteUnits(BLOCK_ALIGN);
/// 256 w/ avx2
pub const BITSET_BLOCKS = @divExact(@sizeOf(root.Bitset), @sizeOf(root.Block));
/// length of a block of u16s, 16 w/ avx2
pub const BLOCK_LEN16 = @divExact(BLOCK_BYTES, 2);
pub const MAX_CONTAINER_BLOCKS = BITSET_BLOCKS;
/// Bitset.blocks should never actually get this big.
pub const MAX_BLOCKS = MAX_CONTAINERS * MAX_CONTAINER_BLOCKS; // 1<<16 * 1<<8 = 1<<24
/// blocks needed by a zroaring.Array (not ArrayContainer)
pub const HEADER_BLOCKS = @divExact(@sizeOf(root.Array), @sizeOf(root.Block)); // 1

const std = @import("std");
const assert = std.debug.assert;
const root = @import("root.zig");
