const std = @import("std");

const debug = std.debug;
const math = std.math;
const mem = std.mem;
const testing = std.testing;

const default_mask = 0x80;
const threshold = 2;

pub fn decode(allocator: mem.Allocator, data: []const u8) ![]u8 {
    const Lengths = struct {
        enc: u32,
        dec: u32,
        pak: u32,
        raw: u32,
    };

    if (data.len < 8)
        return error.BadHeader;

    const inc_len = mem.readInt(u32, data[data.len - 4 ..][0..4], .little);
    const lengths = if (inc_len == 0) blk: {
        break :blk Lengths{
            .enc = 0,
            .dec = @intCast(data.len),
            .pak = 0,
            .raw = @intCast(data.len),
        };
    } else blk: {
        const hdr_len = data[data.len - 5];
        if (hdr_len < 8 or hdr_len > 0xB) return error.BadHeaderLength;
        if (data.len <= hdr_len) return error.BadLength;

        const enc_len = mem.readInt(u32, data[data.len - 8 ..][0..4], .little) & 0x00FFFFFF;
        const dec_len = try math.sub(u32, @as(u32, @intCast(data.len)), enc_len);
        const pak_len = try math.sub(u32, enc_len, hdr_len);
        const raw_len = dec_len + enc_len + inc_len;

        if (raw_len > 0x00FFFFFF)
            return error.BadLength;

        break :blk Lengths{
            .enc = enc_len,
            .dec = dec_len,
            .pak = pak_len,
            .raw = raw_len,
        };
    };

    const result = try allocator.alloc(u8, lengths.raw);
    errdefer allocator.free(result);
    const pak_buffer = try allocator.alloc(u8, data.len + 3);
    defer allocator.free(pak_buffer);

    mem.copy(u8, result, data[0..lengths.dec]);
    mem.copy(u8, pak_buffer, data);
    mem.reverse(u8, pak_buffer[lengths.dec .. lengths.dec + lengths.pak]);

    const pak_end = lengths.dec + lengths.pak;
    var pak = lengths.dec;
    var raw = lengths.dec;
    var mask = @as(usize, 0);
    var flags = @as(usize, 0);

    while (raw < lengths.raw) {
        mask = mask >> 1;
        if (mask == 0) {
            if (pak == pak_end) break;

            flags = pak_buffer[pak];
            mask = default_mask;
            pak += 1;
        }

        if (flags & mask == 0) {
            if (pak == pak_end) break;

            result[raw] = pak_buffer[pak];
            raw += 1;
            pak += 1;
        } else {
            if (pak + 1 >= pak_end) break;

            const pos = (@as(usize, pak_buffer[pak]) << 8) | pak_buffer[pak + 1];
            pak += 2;

            const len = (pos >> 12) + threshold + 1;
            if (raw + len > lengths.raw)
                return error.WrongDecodedLength;

            const new_pos = (pos & 0xFFF) + 3;
            var i = @as(usize, 0);
            while (i < len) : (i += 1) {
                result[raw] = result[raw - new_pos];
                raw += 1;
            }
        }
    }

    if (raw != lengths.raw) return error.UnexpectedEnd;

    mem.reverse(u8, result[lengths.dec..lengths.raw]);
    return result[0..raw];
}

pub fn encode(allocator: mem.Allocator, data: []const u8, start: usize) ![]u8 {
    var pos_best: usize = 0;
    var flg: usize = 0;
    var inc_len: usize = 0;
    var hdr_len: usize = 0;
    var enc_len: usize = 0;

    const raw_buffer = try allocator.dupe(u8, data);
    const raw_len = raw_buffer.len;
    defer allocator.free(raw_buffer);

    var pak_tmp: usize = 0;
    var raw_tmp = raw_len;

    var pak_len = raw_len + ((raw_len + 7) / 8) + 11;
    var pak_buffer = try allocator.alloc(u8, pak_len);

    var raw_new = raw_len - start;
    mem.reverse(u8, raw_buffer);

    var pak: usize = 0;
    var raw: usize = 0;
    var raw_end = raw_new;

    var mask: usize = 0;
    while (raw < raw_end) {
        mask = mask >> 1;
        if (mask == 0) {
            flg = pak;
            pak += 1;
            pak_buffer[flg] = 0;
            mask = 0x80;
        }

        const match = search(pos_best, raw_buffer, raw, raw_end);
        pos_best = @intFromPtr(match.ptr) - @intFromPtr(raw_buffer.ptr);

        pak_buffer[flg] = (pak_buffer[flg] << 1);
        if (match.len > threshold) {
            raw += match.len;
            pak_buffer[flg] |= 1;
            pak_buffer[pak + 0] = @as(u8, @truncate(((match.len - (threshold + 1)) << 4) | ((pos_best - 3) >> 8)));
            pak_buffer[pak + 1] = @as(u8, @truncate(pos_best - 3));
            pak += 2;
        } else {
            pak_buffer[pak] = raw_buffer[raw];
            pak += 1;
            raw += 1;
        }

        if (pak + raw_len - raw < pak_tmp + raw_tmp) {
            pak_tmp = pak;
            raw_tmp = raw_len - raw;
        }
    }

    while ((mask > 0) and (mask != 1)) {
        mask = (mask >> 1);
        pak_buffer[flg] = pak_buffer[flg] << 1;
    }

    pak_len = pak;

    mem.reverse(u8, raw_buffer);
    mem.reverse(u8, pak_buffer[0..pak_len]);

    if (pak_tmp == 0 or (raw_len + 4 < ((pak_tmp + raw_tmp + 3) & 0xFFFFFFFC) + 8)) {
        pak = 0;
        raw = 0;
        raw_end = raw_len;

        while (raw < raw_end) {
            pak_buffer[pak] = raw_buffer[raw];
            pak += 1;
            raw += 1;
        }

        while ((pak & 3) > 0) {
            pak_buffer[pak] = 0;
            pak += 1;
        }

        pak_buffer[pak + 0] = 0;
        pak_buffer[pak + 1] = 0;
        pak_buffer[pak + 2] = 0;
        pak_buffer[pak + 3] = 0;
        pak += 4;
    } else {
        var tmp = try allocator.alloc(u8, raw_tmp + pak_tmp + 11);
        defer allocator.free(tmp);

        mem.copy(u8, tmp[0..raw_tmp], raw_buffer[0..raw_tmp]);
        mem.copy(u8, tmp[raw_tmp..][0..pak_tmp], pak_buffer[pak_len - pak_tmp ..][0..pak_tmp]);

        pak = 0;
        mem.swap([]u8, &pak_buffer, &tmp);

        pak = raw_tmp + pak_tmp;

        enc_len = pak_tmp;
        hdr_len = 8;
        inc_len = raw_len - pak_tmp - raw_tmp;

        while ((pak & 3) > 0) {
            pak_buffer[pak] = 0xFF;
            pak += 1;
            hdr_len += 1;
        }

        mem.writeInt(u32, pak_buffer[pak..][0..4], @as(u32, @intCast(enc_len + hdr_len)), .little);
        pak += 3;
        pak_buffer[pak] = @intCast(hdr_len);
        pak += 1;
        mem.writeInt(u32, pak_buffer[pak..][0..4], @as(u32, @intCast(inc_len - hdr_len)), .little);
        pak += 4;
    }

    return allocator.realloc(pak_buffer, pak);
}

fn search(_p: usize, raw_buffer: []const u8, raw: usize, raw_end: usize) []const u8 {
    const blz_f = 0x12;
    // The original 0x1002 is too big a window to search if we want compression to be fast.
    // Lower it to something more reasonable. This should not affect rom loading from emulators
    // in any way, as this compression method does not care about the window size when decoding.
    // const blz_n = 0x1002;
    const blz_n = 0x128;
    const max = @min(raw, blz_n);

    var p = _p;
    var l: usize = threshold;
    var pos: usize = 0;
    while (true) : (pos += 1) {
        while (pos <= max and raw_buffer[raw] != raw_buffer[raw - pos]) : (pos += 1) {}
        if (pos > max)
            break;

        var len: usize = 1;
        while (len < blz_f) : (len += 1) {
            if (raw + len == raw_end)
                break;
            if (len >= pos)
                break;
            if (raw_buffer[raw + len] != raw_buffer[raw + len - pos])
                break;
        }

        if (len > l) {
            p = pos;
            l = len;
            if (l == blz_f)
                break;
        }
    }
    return raw_buffer[p..][0..l];
}

fn testIt(expected_decoded: []const u8, expected_encoded: []const u8) !void {
    const allocator = testing.allocator;

    const encoded = try encode(allocator, expected_decoded, 0);
    defer allocator.free(encoded);
    try testing.expectEqualSlices(u8, expected_encoded, encoded);

    const decoded = try decode(allocator, expected_encoded);
    defer allocator.free(decoded);
    try testing.expectEqualSlices(u8, expected_decoded, decoded);
}

test "blz" {
    // Tests are only valid for original 0x1002 window
    var disabled = true;
    if (disabled)
        return error.SkipZigTest;

    try testIt(&[_]u8{
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7, 0xaa,
    }, &[_]u8{
        0x0c, 0x30, 0x1b, 0xf0, 0xc0, 0x1b, 0xf0, 0x1b, 0xf0, 0x1b, 0xf0, 0x1b, 0xf0, 0x1b, 0xf0,
        0x1b, 0xf0, 0x1b, 0xf0, 0x1b, 0xf0, 0xff, 0x1b, 0xf0, 0x1b, 0xf0, 0x1b, 0xf0, 0x1b, 0xf0,
        0x1b, 0xf0, 0x1b, 0xf0, 0x1b, 0xf0, 0x1b, 0xf0, 0xff, 0x1b, 0xf0, 0x1b, 0xf0, 0x1b, 0xf0,
        0x1b, 0xf0, 0x1b, 0xf0, 0x1b, 0xf0, 0x1b, 0xf0, 0x1b, 0xf0, 0xff, 0x1b, 0xf0, 0x1b, 0xf0,
        0x1b, 0xf0, 0x1b, 0xf0, 0x1b, 0xf0, 0x1b, 0xf0, 0x1b, 0xf0, 0x1b, 0xf0, 0xff, 0x0c, 0xc0,
        0x29, 0xec, 0x8b, 0x64, 0x54, 0xec, 0x45, 0x01, 0xa6, 0x23, 0x5d, 0x5d, 0xd1, 0x7a, 0xe7,
        0xaa, 0x00, 0x64, 0x00, 0x00, 0x08, 0x12, 0x02, 0x00, 0x00,
    });

    try testIt(
        "770777d9febe1b7b0b5a54820387a621e596e6e3898341fa23ed6e8a82ac3f8b9e5b3001359725ada77a" ++
            "4128d9a99cd55b4632273248ce2267a47d5f669efe7823a9e8b7bdfe8f42de9faabbb3c4b5cbcfd62" ++
            "1cdfa1a7885265830d5ed994627ad6096359d76b0a2bf998b3b05aab7c36a3406998fdb6397b25964" ++
            "3bd4a25566d8844c23a1809477fb2b1eb057b7143e4d156a912d8b26b5acdb3508bbed38f708f1fee" ++
            "4128d9a99cd55b4632273248ce2267a47d5f669efe7823a9e8b7bdfe8f42de9faabbb3c4b5cbcfd62" ++
            "877105d87b9257a388e28cd782d963a7132a1ba0e1db92afc2380a7bbfa4523fbfb7579bfa6c8255a" ++
            "16d5b4a0335a41ceab4fcff223404e23d4c198bbc9c7d44980bc00628965111b1f5e430ce8923f1ca" ++
            "3bd4a25566d8844c23a1809477fb2b1eb057b7143e4d156a912d8b26b5acdb3508bbed38f708f1fee" ++
            "7f069798a16475649ad3e2cc54b2a70f5084fc25ff73ce879c898ecbaa46e4e2b69e43fdd46da210f" ++
            "adb0272e6e621914a03d98b464a28d975c4660680dfb0777897e7551d9f8c8c1d16513ca19d1f0fbb",
        &[_]u8{
            0x37, 0x37, 0x03, 0x13, 0x0b, 0x03, 0x65, 0x62, 0x30, 0x65, 0x31, 0x76, 0x00, 0x30,
            0x1a, 0x01, 0x35, 0x34, 0x38, 0x14, 0x32, 0x30, 0x33, 0x38, 0x37, 0x61, 0x83, 0x00,
            0x65, 0x40, 0xce, 0x00, 0xbc, 0x02, 0x33, 0x92, 0x02, 0x33, 0x34, 0x31, 0x66, 0x0b,
            0x61, 0x32, 0x33, 0x65, 0x64, 0x36, 0x65, 0x38, 0x00, 0x61, 0x38, 0x32, 0x61, 0x63,
            0x33, 0x66, 0x38, 0x00, 0x62, 0x39, 0x65, 0x35, 0x62, 0x33, 0x30, 0x30, 0x00, 0x31,
            0x7b, 0x00, 0x37, 0x32, 0x35, 0x61, 0x64, 0x61, 0x02, 0x37, 0x37, 0x61, 0xf0, 0x40,
            0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf8, 0x40, 0x02, 0x63, 0x64, 0x66,
            0x61, 0x31, 0x61, 0x37, 0x01, 0x38, 0x38, 0x35, 0x32, 0x36, 0x35, 0x38, 0x33, 0x00,
            0x30, 0x64, 0x35, 0x65, 0x64, 0x39, 0x39, 0x34, 0x00, 0x36, 0x32, 0x37, 0x61, 0x64,
            0x36, 0x30, 0xec, 0x00, 0x80, 0x35, 0x39, 0x64, 0x37, 0x36, 0x62, 0x30, 0x61, 0x00,
            0x32, 0x62, 0x66, 0x39, 0x37, 0x01, 0x33, 0x3c, 0x00, 0xaa, 0x00, 0xd0, 0x37, 0x63,
            0x33, 0x36, 0x61, 0x33, 0x34, 0xa6, 0x01, 0x80, 0x39, 0x38, 0x66, 0x64, 0x62, 0x36,
            0x33, 0x39, 0x00, 0x37, 0x62, 0x32, 0x35, 0x39, 0x36, 0x34, 0x41, 0x61, 0x80, 0x41,
            0xf1, 0x41, 0xf1, 0x41, 0xf1, 0x41, 0xf1, 0x34, 0x31, 0xab, 0x11, 0x61, 0x4f, 0x39,
            0x39, 0x63, 0x64, 0x35, 0x35, 0x9b, 0x01, 0x33, 0x40, 0x32, 0x32, 0x37, 0x33, 0x32,
            0x34, 0x38, 0x63, 0x00, 0x65, 0x32, 0x32, 0x36, 0x37, 0x61, 0x34, 0x37, 0x00, 0x64,
            0x35, 0x66, 0x36, 0x5d, 0x01, 0x66, 0x65, 0x37, 0x10, 0x38, 0xd4, 0x00, 0x39, 0x65,
            0x38, 0x62, 0x37, 0x62, 0x02, 0x64, 0x66, 0x65, 0x38, 0x66, 0x34, 0x32, 0x64, 0x00,
            0x65, 0x39, 0x66, 0x61, 0x61, 0x62, 0x62, 0x62, 0x00, 0x33, 0x63, 0x34, 0x62, 0x35,
            0x63, 0x62, 0x63, 0x00, 0x66, 0x64, 0x86, 0x00, 0x37, 0x37, 0x31, 0x30, 0x35, 0x04,
            0x64, 0x38, 0x37, 0x1f, 0x00, 0x35, 0x37, 0x61, 0x33, 0x08, 0x38, 0x38, 0x65, 0x32,
            0x38, 0x63, 0x64, 0x37, 0x00, 0x38, 0x32, 0x64, 0x39, 0x36, 0x33, 0x61, 0x37, 0x00,
            0x31, 0x33, 0x32, 0x61, 0x31, 0x62, 0x61, 0x30, 0x00, 0x65, 0x31, 0x64, 0x62, 0x39,
            0x32, 0x61, 0x66, 0x00, 0x7e, 0x00, 0x38, 0x30, 0x61, 0x37, 0x62, 0x0c, 0x00, 0x34,
            0x41, 0x35, 0x5c, 0x00, 0x62, 0x66, 0x62, 0x37, 0x35, 0x37, 0x02, 0x39, 0x62, 0x66,
            0x61, 0x36, 0x63, 0x38, 0x57, 0x00, 0x80, 0xa8, 0x00, 0x64, 0x35, 0x62, 0xfa, 0x10,
            0x33, 0x35, 0x61, 0x11, 0x34, 0x31, 0x63, 0x65, 0x61, 0x62, 0xb0, 0x00, 0x66, 0x40,
            0x66, 0x32, 0x32, 0x33, 0x34, 0x30, 0xc0, 0x00, 0x33, 0x40, 0x64, 0x34, 0x63, 0x31,
            0x39, 0x6a, 0x00, 0x63, 0x39, 0x20, 0x63, 0x37, 0x64, 0x34, 0x34, 0x39, 0x38, 0x30,
            0x00, 0x62, 0x63, 0x30, 0x30, 0x36, 0x32, 0x38, 0x39, 0x00, 0xf8, 0x00, 0x31, 0x31,
            0x62, 0x31, 0x66, 0x35, 0x9f, 0x00, 0x81, 0x30, 0x84, 0x00, 0x39, 0x32, 0x33, 0x66,
            0x31, 0x63, 0x02, 0x61, 0x33, 0x62, 0x64, 0xb5, 0x00, 0x35, 0x35, 0x36, 0x10, 0x36,
            0x64, 0x38, 0x38, 0x34, 0x34, 0x63, 0x32, 0x00, 0x33, 0x61, 0x31, 0x38, 0x30, 0x39,
            0x34, 0x37, 0x00, 0x37, 0x66, 0x62, 0x32, 0x62, 0x31, 0x65, 0x62, 0x00, 0x30, 0x35,
            0x37, 0x62, 0x37, 0x31, 0x34, 0x33, 0x00, 0x65, 0x34, 0x64, 0x31, 0x35, 0x36, 0x61,
            0x39, 0x00, 0x31, 0x32, 0x64, 0x38, 0x62, 0x32, 0x36, 0x62, 0x00, 0x35, 0x61, 0x63,
            0x64, 0x62, 0x33, 0x2f, 0x00, 0x62, 0x40, 0x62, 0x65, 0x64, 0x33, 0x38, 0x66, 0x37,
            0x30, 0x00, 0x38, 0x66, 0x31, 0x66, 0x65, 0x65, 0x37, 0x66, 0x00, 0x30, 0x36, 0x39,
            0x37, 0x39, 0x38, 0x61, 0x31, 0x00, 0x36, 0x34, 0x37, 0x35, 0x36, 0x34, 0x39, 0x61,
            0x00, 0x64, 0x33, 0x65, 0x32, 0x63, 0x63, 0x35, 0x34, 0x00, 0x62, 0x32, 0x61, 0x37,
            0x30, 0x66, 0x35, 0x30, 0x00, 0x38, 0x34, 0x66, 0x63, 0x32, 0x35, 0x66, 0x66, 0x00,
            0x37, 0x33, 0x63, 0x65, 0x38, 0x37, 0x39, 0x63, 0x00, 0x38, 0x39, 0x38, 0x65, 0x63,
            0x62, 0x61, 0x61, 0x00, 0x34, 0x36, 0x65, 0x34, 0x65, 0x32, 0x62, 0x36, 0x00, 0x39,
            0x65, 0x34, 0x33, 0x66, 0x64, 0x64, 0x34, 0x00, 0x36, 0x64, 0x61, 0x32, 0x31, 0x30,
            0x66, 0x61, 0x00, 0x64, 0x62, 0x30, 0x32, 0x37, 0x32, 0x65, 0x36, 0x00, 0x65, 0x36,
            0x32, 0x31, 0x39, 0x31, 0x34, 0x61, 0x00, 0x30, 0x33, 0x64, 0x39, 0x38, 0x62, 0x34,
            0x36, 0x00, 0x34, 0x61, 0x32, 0x38, 0x64, 0x39, 0x37, 0x35, 0x00, 0x63, 0x34, 0x36,
            0x36, 0x30, 0x36, 0x38, 0x30, 0x00, 0x64, 0x66, 0x62, 0x30, 0x37, 0x37, 0x37, 0x38,
            0x00, 0x39, 0x37, 0x65, 0x37, 0x35, 0x35, 0x31, 0x64, 0x00, 0x39, 0x66, 0x38, 0x63,
            0x38, 0x63, 0x31, 0x64, 0x00, 0x31, 0x36, 0x35, 0x31, 0x33, 0x63, 0x61, 0x31, 0x00,
            0x39, 0x64, 0x31, 0x66, 0x30, 0x66, 0x62, 0x62, 0x00, 0xff, 0xff, 0xff, 0xce, 0x02,
            0x00, 0x0b, 0x5d, 0x00, 0x00, 0x00,
        },
    );
}
