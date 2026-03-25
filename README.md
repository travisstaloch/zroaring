# About
Exploring [CRoaring](https://github.com/RoaringBitmap/CRoaring) by attempting to port it to zig.

This repo is hosted on [codeberg](https://codeberg.org/archaistvolts/zroaring) and mirrored to [github](https://github.com/archaistvolts/zroaring).

# Documentation
[Documentation](https://archaistvolts.github.io/zroaring/) is hosted on github.

# Use
With zig version 0.15.2

Be sure to test your application in debug mode as there are many unreachable code paths left as TODOs.

### fetch package
```console
$ zig fetch --save git+https://codeberg.org/archaistvolts/zroaring
```
```zig
// build.zig
const zroaring_dep = b.dependency("zroaring", .{ .target = target, .optimize = optimize });
const exe_mod = b.createModule(.{
    // ...
    .imports = &.{
        .{ .name = "zroaring", .module = zroaring_dep.module("zroaring") },
    },
});
```
```zig
// app.zig
const zroaring = @import("zroaring");
var zr: zroaring.Bitmap = .{};
defer zr.deinit(std.testing.allocator);
try zr.add(std.testing.allocator, 1);
try std.testing.expect(zr.contains(1));
try std.testing.expect(!zr.contains(2));
```

# Contributing
Human contributions are very welcome.  Please open a pull request or issue on codeberg if you run into a TODO, FIXME or any problems while using this project.  There is a lot of work yet to be done here.

# References
* https://github.com/RoaringBitmap/RoaringFormatSpec
* https://github.com/RoaringBitmap/CRoaring
* https://github.com/awesomo4000/rawr
* https://github.com/lalinsky/roaring.zig

# Ideas / TODOs - contributions wanted
* [ ] Provide a similar api to std.HashMap
* [ ] Bounded API: initBuffer, appendBounded
* [ ] Support more set sizes than just u32 with generics and a build option
* [ ] build commands `$ zig build [api-coverage | correctness | bench]`
  * [ ] api-coverage:    show % of c api covered
  * [ ] api-correctness: show % correct fuzzing with c api oracle
  * [ ] api-endian:      show which api methods are endian sensitive - big endian write to file
  * [ ] bench:           show timings of bench with c
* [ ] documentation needs a lot of work
  * [ ] audit endian-sensitive warnings in comments
* [ ] prune comments.  i've used many of original CRoaring comments and some of them don't apply to this implementation.
* [ ] audit endian sensitive methods.  i've tried for endian.
* [ ] audit unreachable code paths.  return error.Unimplemented when possible for starters.
* [ ] For now this a port of CRoaring.  Maybe this project will transition to a more from-scratch approach with time and familiarity.  Goal would be to reduce the codebase size without sacrificing performance.
* [ ] use in regex / peg impl in another project maybe following https://github.com/MartinErhardt/RoaringRegex
