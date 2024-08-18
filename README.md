# pmparse

A small library to parse the memory mappings of a process on Linux.

## Usage

```zig
const std = @import("std");
const ProcessMaps = @import("pmparse").ProcessMaps;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    _ = defer gpa.deinit();
    const allocator = gpa.allocator();

    // create an iterator for maps of a process.
    // if the `pid` is null, /proc/self/maps is used.
    const maps = try ProcessMaps.init(allocator, null);

    while (try maps.next()) |map| {
        defer map.deinit(allocator);
        std.debug.print("{}\n", .{map}); // start-end mode offset major:minor inode path
    }
}
```
