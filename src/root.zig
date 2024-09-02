const std = @import("std");
const max_map_line_length = std.posix.PATH_MAX + 100;

pub const ProcessMaps = struct {
    allocator: std.mem.Allocator,
    maps: std.fs.File,

    pub const InitError = std.fmt.BufPrintError || std.fs.File.OpenError;
    pub const ParseError = error{ StreamTooLong, EndOfStream } || std.posix.ReadError || std.mem.Allocator.Error || std.fmt.ParseIntError;

    /// Initialize an iterator for mappings of a process.
    /// If `pid` is null, /proc/self/maps is read.
    pub fn init(allocator: std.mem.Allocator, pid: ?usize) InitError!ProcessMaps {
        var path_buf: [500]u8 = .{0} ** 500;

        const maps = try std.fs.openFileAbsolute(if (pid) |p|
            try std.fmt.bufPrint(&path_buf, "/proc/{d}/maps", .{p})
        else
            try std.fmt.bufPrint(&path_buf, "/proc/self/maps", .{}), .{});

        return .{
            .allocator = allocator,
            .maps = maps,
        };
    }

    pub fn deinit(iter: ProcessMaps) void {
        iter.maps.close();
    }

    pub fn next(iter: ProcessMaps) ParseError!?ProcessMap {
        var line_buffer: [max_map_line_length]u8 = .{0} ** max_map_line_length;

        const line = try iter.maps.reader().readUntilDelimiterOrEof(&line_buffer, '\n') orelse return null;
        var stream = std.io.fixedBufferStream(line);
        const mapping = stream.reader();

        // 00000000h-00000000h
        const start = try std.fmt.parseInt(usize, (try mapping.readUntilDelimiter(line, '-')), 16);
        const end = try std.fmt.parseInt(usize, (try mapping.readUntilDelimiter(line, ' ')), 16);

        // rwxp
        const r = try mapping.readByte();
        const w = try mapping.readByte();
        const x = try mapping.readByte();
        const p = try mapping.readByte();

        // whitespace
        _ = try mapping.readByte();

        // 00000000h
        const offset = try std.fmt.parseInt(usize, (try mapping.readUntilDelimiter(line, ' ')), 16);

        // 00:00
        const major = try std.fmt.parseInt(u32, (try mapping.readUntilDelimiter(line, ':')), 10);
        const minor = try std.fmt.parseInt(u32, (try mapping.readUntilDelimiter(line, ' ')), 10);

        const inode = try std.fmt.parseInt(u32, (try mapping.readUntilDelimiter(line, ' ')), 10);

        const path = if (stream.pos == line.len) null else path: {
            var padding_len: usize = 0;
            while (line[stream.pos + padding_len] == ' ') : (padding_len += 1) {}
            const path_buf = try iter.allocator.alloc(u8, line.len - stream.pos - padding_len);

            @memcpy(path_buf, line[stream.pos + padding_len ..]);
            break :path path_buf;
        };

        return .{
            .start = start,
            .end = end,
            .mode = .{ .read = r == 'r', .write = w == 'w', .execute = x == 'x', .private = p == 'p' },
            .offset = offset,
            .id = .{ .major = major, .minor = minor },
            .inode = inode,
            .path = path,
        };
    }
};

pub const ProcessMap = struct {
    const Mode = packed struct {
        read: bool,
        write: bool,
        execute: bool,
        private: bool,

        pub fn format(
            mode: Mode,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) @TypeOf(writer).Error!void {
            _ = fmt;
            _ = options;
            try writer.print("{c}{c}{c}{c}", .{
                // NOTE: compiler can't derive the type of the first branch for some reason
                if (mode.read) @as(u8, 'r') else '-',
                if (mode.write) @as(u8, 'w') else '-',
                if (mode.execute) @as(u8, 'x') else '-',
                if (mode.private) @as(u8, 'p') else '-',
            });
        }
    };

    /// area beginning address
    start: usize,
    /// area end address
    end: usize,
    /// mode of the mapping
    mode: Mode,
    /// mapping offset
    offset: usize,
    /// mapped device
    id: struct { major: u32, minor: u32 },
    /// inode of the backing file
    inode: u32,
    /// backing file path
    /// null if the region is anonymous
    path: ?[]u8,

    /// Get a pointer to this region
    pub fn ptr(map: ProcessMap) *anyopaque {
        return @ptrFromInt(map.start);
    }

    /// Create a slice of this region
    pub fn slice(map: ProcessMap) *[]u8 {
        return @as([*]u8, map.ptr())[0..map.size()];
    }

    /// calculate the size of the mapped memory region
    pub fn size(map: ProcessMap) usize {
        return map.end - map.start;
    }

    pub fn deinit(map: ProcessMap, allocator: std.mem.Allocator) void {
        if (map.path) |path| {
            allocator.free(path);
        }
    }

    pub fn format(
        map: ProcessMap,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;

        try writer.print("{x:0>8}-{x:0>8} {} {x:0>8} {d:0>2}:{d:0>2} {d} {s}", .{
            map.start,
            map.end,
            map.mode,
            map.offset,
            map.id.major,
            map.id.minor,
            map.inode,
            if (map.path) |path| path else "",
        });
    }
};

test {
    const allocator = std.testing.allocator;
    const maps = try ProcessMaps.init(allocator, null);
    while (try maps.next()) |map| {
        map.deinit(allocator);
    }
}
