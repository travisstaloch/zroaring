//!
//! A Roaring Bitmap implementation inspired by CRoaring.
//!  * https://github.com/RoaringBitmap/CRoaring
//!  * https://github.com/RoaringBitmap/RoaringFormatSpec
//!

pub const zroaring = @This();

pub const Bitmap = @import("Bitmap.zig");
pub const Block = @Vector(constants.BLOCK_LEN, u8);
pub const Bitset = [1024]u64;
pub const constants = @import("constants.zig");

pub const Magic = enum(u16) {
    SERIAL_COOKIE_NO_RUNCONTAINER = 12346,
    SERIAL_COOKIE = 12347,
    FROZEN_COOKIE = 13766,
    _,
};

/// # Cookie header
/// The cookie header spans either 64 bits or 32 bits followed by a variable number of bytes.
/// Magic cookie value that identifies the type of Roaring Bitmap format.
/// 12346 (SERIAL_COOKIE_NO_RUNCONTAINER) means no run containers are used.
/// 12347 (SERIAL_COOKIE) means run containers may be present.
pub const Cookie = extern struct {
    magic: Magic,
    cardinality_minus1: u16,
};

pub const Rle16 = struct { value: u16, length: u16 };

test {
    _ = Bitmap;
    _ = @import("validate.zig");
    // _ = @import("fuzz.zig");
}
