pub const root = @cImport({
    // @cDefine("CROARING_COMPILER_SUPPORTS_AVX512", "0");
    @cDefine("CROARING_ATOMIC_IMPL", "1"); // 0.15.2 translate-c doesn't support atomics
    @cInclude("c/roaring.h");
});
