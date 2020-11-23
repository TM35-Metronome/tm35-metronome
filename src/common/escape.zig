const std = @import("std");

const debug = std.debug;
const io = std.io;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const chars = blk: {
    var res: [255]u8 = undefined;
    for (res) |*char, i|
        char.* = @intCast(u8, i);

    break :blk res;
};

pub const default_escapes = blk: {
    var res: [255][]const u8 = undefined;
    for (res) |*slice, i|
        slice.* = @as(*const [1]u8, &chars[i])[0..];

    break :blk res;
};

pub const zig_escapes = comptime blk: {
    var res: [255][]const u8 = undefined;
    mem.copy([]const u8, res[0..], &default_escapes);
    res['\r'] = "\\r";
    res['\n'] = "\\n";
    res['\\'] = "\\\\";
    break :blk res;
};

pub fn writeEscaped(writer: anytype, buf: []const u8, escapes: [255][]const u8) !void {
    for (buf) |char| {
        try writer.writeAll(escapes[char]);
    }
}

pub fn escape(allocator: *mem.Allocator, buf: []const u8, escapes: [255][]const u8) ![]u8 {
    var res = std.ArrayList(u8).init(allocator);
    errdefer res.deinit();

    try res.ensureCapacity(buf.len);
    try writeEscape(res.writer(), buf, escapes);
    return res.toOwnedSlice();
}

test "writeEscaped" {
    var comma_escape = default_escapes;
    comma_escape[','] = "\\,";

    testWriteEscaped(comma_escape, "abc", "abc");
    testWriteEscaped(comma_escape, "a,bc", "a\\,bc");
    testWriteEscaped(comma_escape, "a,b,c", "a\\,b\\,c");
    testWriteEscaped(comma_escape, "a,,b,,c", "a\\,\\,b\\,\\,c");
    testWriteEscaped(comma_escape, "a\\,,b,,c", "a\\\\,\\,b\\,\\,c");
}

fn testWriteEscaped(escapes: [255][]const u8, str: []const u8, expect: []const u8) void {
    var buf: [1024]u8 = undefined;
    var fbs = io.fixedBufferStream(&buf);
    writeEscaped(fbs.writer(), str, escapes) catch unreachable;
    testing.expectEqualStrings(expect, fbs.getWritten());
}

pub fn writeUnEscaped(writer: anytype, buf: []const u8, escapes: [255][]const u8) !void {
    var index: usize = 0;
    outer: while (index < buf.len) {
        for (escapes) |esc, c| {
            if (mem.startsWith(u8, buf[index..], esc)) {
                index += esc.len;
                try writer.writeAll(@as(*const [1]u8, &@intCast(u8, c)));
                continue :outer;
            }
        }

        try writer.writeAll(buf[index .. index + 1]);
        index += 1;
    }
}

pub fn unEscape(allocator: *mem.Allocator, buf: []const u8, escapes: [255][]const u8) ![]u8 {
    var res = std.ArrayList(u8).init(allocator);
    errdefer res.deinit();

    try res.ensureCapacity(buf.len);
    try writeUnEscaped(res.writer(), buf, escapes);
    return res.toOwnedSlice();
}

test "writeUnEscaped" {
    var comma_escape = default_escapes;
    comma_escape[','] = "\\,";

    testWriteUnEscaped(comma_escape, "abc", "abc");
    testWriteUnEscaped(comma_escape, "a\\,bc", "a,bc");
    testWriteUnEscaped(comma_escape, "a\\,b\\,c", "a,b,c");
    testWriteUnEscaped(comma_escape, "a\\,,b\\,\\,c", "a,,b,,c");
}

fn testWriteUnEscaped(escapes: [255][]const u8, str: []const u8, expect: []const u8) void {
    var buf: [1024]u8 = undefined;
    var fbs = io.fixedBufferStream(&buf);
    writeUnEscaped(fbs.writer(), str, escapes) catch unreachable;
    testing.expectEqualStrings(expect, fbs.getWritten());
}

pub fn splitEscaped(buffer: []const u8, esc: []const u8, delimiter: []const u8) EscapedSplitter {
    std.debug.assert(delimiter.len != 0);
    return EscapedSplitter{
        .index = 0,
        .buffer = buffer,
        .escape = esc,
        .delimiter = delimiter,
    };
}

pub const EscapedSplitter = struct {
    buffer: []const u8,
    index: ?usize,
    escape: []const u8,
    delimiter: []const u8,

    /// Returns a slice of the next field, or null if splitting is complete.
    pub fn next(self: *EscapedSplitter) ?[]const u8 {
        const start = self.index orelse return null;
        var start2 = start;

        const end = blk: {
            while (true) {
                if (mem.indexOfPos(u8, self.buffer, start2, self.delimiter)) |delim_start| {
                    if (delim_start >= self.escape.len and
                        mem.eql(u8, self.buffer[delim_start - self.escape.len .. delim_start], self.escape))
                    {
                        start2 = delim_start + self.escape.len;
                        continue;
                    }

                    self.index = delim_start + self.delimiter.len;
                    break :blk delim_start;
                } else {
                    self.index = null;
                    break :blk self.buffer.len;
                }
            }

            unreachable;
        };
        return self.buffer[start..end];
    }

    /// Returns a slice of the remaining bytes. Does not affect iterator state.
    pub fn rest(self: EscapedSplitter) []const u8 {
        const end = self.buffer.len;
        const start = self.index orelse end;
        return self.buffer[start..end];
    }
};

test "splitEscaped" {
    var it = splitEscaped("abc|def||ghi\\|jkl", "\\", "|");
    testing.expectEqualStrings("abc", it.next().?);
    testing.expectEqualStrings("def", it.next().?);
    testing.expectEqualStrings("", it.next().?);
    testing.expectEqualStrings("ghi\\|jkl", it.next().?);
    testing.expect(it.next() == null);

    it = splitEscaped("", "\\", "|");
    testing.expectEqualStrings("", it.next().?);
    testing.expect(it.next() == null);

    it = splitEscaped("|", "\\", "|");
    testing.expectEqualStrings("", it.next().?);
    testing.expectEqualStrings("", it.next().?);
    testing.expect(it.next() == null);

    it = splitEscaped("hello", "\\", " ");
    testing.expectEqualStrings(it.next().?, "hello");
    testing.expect(it.next() == null);

    it = splitEscaped("\\,\\,,", "\\", ",");
    testing.expectEqualStrings(it.next().?, "\\,\\,");
    testing.expectEqualStrings(it.next().?, "");
    testing.expect(it.next() == null);
}

test "splitEscaped (multibyte)" {
    var it = splitEscaped("a, b ,, c, d, e\\\\, f", "\\\\", ", ");
    testing.expectEqualStrings(it.next().?, "a");
    testing.expectEqualStrings(it.next().?, "b ,");
    testing.expectEqualStrings(it.next().?, "c");
    testing.expectEqualStrings(it.next().?, "d");
    testing.expectEqualStrings(it.next().?, "e\\\\, f");
    testing.expect(it.next() == null);
}
