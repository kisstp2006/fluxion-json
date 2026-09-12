// SPDX-License-Identifier: CC0-1.0

//! CBOR (RFC 8949): the same values as JSON, in binary. What a `Writer`
//! writes and a `Reader` reads when their format is `.cbor`.
//!
//! Every item is a head - a major type and a number - and what the number
//! says follows: that many bytes of text, that many items of an array, the
//! value itself for an integer. The head takes the fewest bytes its number
//! fits in, and a float the fewest bytes that hold it exactly, which is RFC
//! 8949's preferred serialization.

const std = @import("std");
const testing = std.testing;

const utf8 = @import("utf8.zig");

/// Tag 55799, which marks bytes as CBOR and means nothing else. Written at
/// the start of every document, and what `Reader` looks for to tell CBOR
/// from JSON text: no JSON text can start with these bytes.
pub const self_described = [3]u8{ 0xD9, 0xD9, 0xF7 };

/// What closes a map or an array whose length was not given when it opened.
pub const break_byte: u8 = 0xFF;

pub const Major = enum(u3) { unsigned, negative, bytes, text, array, map, tag, simple };

/// The additional information that means "no length given".
pub const indefinite: u5 = 31;

pub const Head = struct {
    major: Major,
    info: u5,
    /// The value, the length or the count - or a float's bits, for `.simple`.
    argument: u64,
    /// How many bytes the head took.
    size: u8,
};

pub const HeadError = error{
    /// The bytes end inside the head.
    Truncated,
    /// Additional information 28 to 30, which RFC 8949 reserves.
    Reserved,
};

pub fn readHead(bytes: []const u8) HeadError!Head {
    if (bytes.len == 0) return error.Truncated;
    const major: Major = @enumFromInt(bytes[0] >> 5);
    const info: u5 = @intCast(bytes[0] & 0x1F);
    const size: u8 = switch (info) {
        0...23, indefinite => 1,
        24 => 2,
        25 => 3,
        26 => 5,
        27 => 9,
        28...30 => return error.Reserved,
    };
    if (bytes.len < size) return error.Truncated;
    const argument: u64 = switch (size) {
        1 => if (info == indefinite) 0 else info,
        2 => bytes[1],
        3 => std.mem.readInt(u16, bytes[1..3], .big),
        5 => std.mem.readInt(u32, bytes[1..5], .big),
        else => std.mem.readInt(u64, bytes[1..9], .big),
    };
    return .{ .major = major, .info = info, .argument = argument, .size = size };
}

pub fn writeHead(out: *std.Io.Writer, major: Major, argument: u64) std.Io.Writer.Error!void {
    const m = @as(u8, @intFromEnum(major)) << 5;
    var buf: [9]u8 = undefined;
    const size: usize = if (argument < 24) blk: {
        buf[0] = m | @as(u8, @intCast(argument));
        break :blk 1;
    } else if (argument <= std.math.maxInt(u8)) blk: {
        buf[0] = m | 24;
        buf[1] = @intCast(argument);
        break :blk 2;
    } else if (argument <= std.math.maxInt(u16)) blk: {
        buf[0] = m | 25;
        std.mem.writeInt(u16, buf[1..3], @intCast(argument), .big);
        break :blk 3;
    } else if (argument <= std.math.maxInt(u32)) blk: {
        buf[0] = m | 26;
        std.mem.writeInt(u32, buf[1..5], @intCast(argument), .big);
        break :blk 5;
    } else blk: {
        buf[0] = m | 27;
        std.mem.writeInt(u64, buf[1..9], argument, .big);
        break :blk 9;
    };
    try out.writeAll(buf[0..size]);
}

/// The head an integer is written with, or null when it is outside what CBOR
/// holds, -2^64 to 2^64 - 1.
pub fn intHead(value: anytype) ?struct { major: Major, argument: u64 } {
    if (value >= 0) {
        const n = std.math.cast(u64, value) orelse return null;
        return .{ .major = .unsigned, .argument = n };
    }
    const wide = std.math.cast(i128, value) orelse return null;
    const n = std.math.cast(u64, -1 - wide) orelse return null;
    return .{ .major = .negative, .argument = n };
}

/// A float in the fewest bytes that hold it exactly: half, single or double
/// precision. NaN and the infinities fit in half.
pub fn writeFloat(out: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const v: f64 = @floatCast(value);
    if (std.math.isNan(v)) return out.writeAll(&.{ 0xF9, 0x7E, 0x00 });
    const half: f16 = @floatCast(v);
    if (@as(f64, half) == v) {
        var buf: [3]u8 = .{ 0xF9, 0, 0 };
        std.mem.writeInt(u16, buf[1..3], @bitCast(half), .big);
        return out.writeAll(&buf);
    }
    const single: f32 = @floatCast(v);
    if (@as(f64, single) == v) {
        var buf: [5]u8 = .{ 0xFA, 0, 0, 0, 0 };
        std.mem.writeInt(u32, buf[1..5], @bitCast(single), .big);
        return out.writeAll(&buf);
    }
    var buf: [9]u8 = undefined;
    buf[0] = 0xFB;
    std.mem.writeInt(u64, buf[1..9], @bitCast(v), .big);
    return out.writeAll(&buf);
}

/// The float a head of additional information 25, 26 or 27 holds. The width
/// it was written in only saved bytes: a half 65504 is 65504, and not the
/// 65500 that is the shortest text a half reads back from.
pub fn floatValue(head: Head) f64 {
    return switch (head.info) {
        25 => @as(f16, @bitCast(@as(u16, @intCast(head.argument)))),
        26 => @as(f32, @bitCast(@as(u32, @intCast(head.argument)))),
        else => @bitCast(head.argument),
    };
}

/// A text string. Bytes that are not UTF-8 become U+FFFD, as they do in JSON
/// text, so what is written is always valid.
pub fn writeText(out: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    const length = repairedLength(s);
    try writeHead(out, .text, length);
    if (length == s.len) return out.writeAll(s);
    var run: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] < 0x80) {
            i += 1;
            continue;
        }
        if (utf8.sequenceLength(s[i..])) |len| {
            i += len;
            continue;
        }
        try out.writeAll(s[run..i]);
        try out.writeAll("\u{FFFD}");
        i += 1;
        run = i;
    }
    try out.writeAll(s[run..]);
}

/// How long `s` is once every byte that is not UTF-8 has become U+FFFD:
/// longer than `s` exactly when there was one.
fn repairedLength(s: []const u8) usize {
    var extra: usize = 0;
    var i: usize = 0;
    while (true) {
        i = utf8.asciiRun(s, i);
        if (i >= s.len) return s.len + extra;
        if (utf8.sequenceLength(s[i..])) |len| {
            i += len;
        } else {
            i += 1;
            extra += "\u{FFFD}".len - 1;
        }
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// Bytes from hex digits, with spaces between them if that reads better: for
/// tests, `hex("d9d9f7 83 01 02 03")`.
pub fn hex(comptime text: []const u8) [std.mem.replacementSize(u8, text, " ", "") / 2]u8 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var digits: [std.mem.replacementSize(u8, text, " ", "")]u8 = undefined;
        _ = std.mem.replace(u8, text, " ", "", &digits);
        var bytes: [digits.len / 2]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, &digits) catch unreachable;
        break :blk bytes;
    };
}

fn expectBytes(comptime expected_hex: []const u8, written: []const u8) !void {
    const expected = hex(expected_hex);
    try testing.expectEqualSlices(u8, &expected, written);
}

fn headBytes(buf: []u8, major: Major, argument: u64) []const u8 {
    var out: std.Io.Writer = .fixed(buf);
    writeHead(&out, major, argument) catch unreachable;
    return out.buffered();
}

fn intBytes(buf: []u8, value: anytype) []const u8 {
    const head = intHead(value).?;
    return headBytes(buf, head.major, head.argument);
}

fn floatBytes(buf: []u8, value: anytype) []const u8 {
    var out: std.Io.Writer = .fixed(buf);
    writeFloat(&out, value) catch unreachable;
    return out.buffered();
}

test "integers take the fewest bytes, as RFC 8949's examples do" {
    var buf: [9]u8 = undefined;
    try expectBytes("00", intBytes(&buf, 0));
    try expectBytes("01", intBytes(&buf, 1));
    try expectBytes("0a", intBytes(&buf, 10));
    try expectBytes("17", intBytes(&buf, 23));
    try expectBytes("1818", intBytes(&buf, 24));
    try expectBytes("1819", intBytes(&buf, 25));
    try expectBytes("1864", intBytes(&buf, 100));
    try expectBytes("1903e8", intBytes(&buf, 1000));
    try expectBytes("1a000f4240", intBytes(&buf, 1000000));
    try expectBytes("1b000000e8d4a51000", intBytes(&buf, 1000000000000));
    try expectBytes("1bffffffffffffffff", intBytes(&buf, @as(u64, std.math.maxInt(u64))));
    try expectBytes("20", intBytes(&buf, -1));
    try expectBytes("29", intBytes(&buf, -10));
    try expectBytes("3863", intBytes(&buf, -100));
    try expectBytes("3903e7", intBytes(&buf, -1000));
    try expectBytes("3bffffffffffffffff", intBytes(&buf, @as(i128, -18446744073709551616)));
    try testing.expect(intHead(@as(i128, -18446744073709551617)) == null);
    try testing.expect(intHead(@as(u128, 18446744073709551616)) == null);
}

test "floats take the fewest bytes that hold them exactly" {
    var buf: [9]u8 = undefined;
    try expectBytes("f90000", floatBytes(&buf, @as(f64, 0.0)));
    try expectBytes("f98000", floatBytes(&buf, @as(f64, -0.0)));
    try expectBytes("f93c00", floatBytes(&buf, @as(f64, 1.0)));
    try expectBytes("fb3ff199999999999a", floatBytes(&buf, @as(f64, 1.1)));
    try expectBytes("f93e00", floatBytes(&buf, @as(f64, 1.5)));
    try expectBytes("f97bff", floatBytes(&buf, @as(f64, 65504.0)));
    try expectBytes("fa47c35000", floatBytes(&buf, @as(f64, 100000.0)));
    try expectBytes("fa7f7fffff", floatBytes(&buf, @as(f64, 3.4028234663852886e+38)));
    try expectBytes("fb7e37e43c8800759c", floatBytes(&buf, @as(f64, 1.0e+300)));
    try expectBytes("f90001", floatBytes(&buf, @as(f64, 5.960464477539063e-8)));
    try expectBytes("f90400", floatBytes(&buf, @as(f64, 0.00006103515625)));
    try expectBytes("f9c400", floatBytes(&buf, @as(f64, -4.0)));
    try expectBytes("fbc010666666666666", floatBytes(&buf, @as(f64, -4.1)));
    try expectBytes("f97c00", floatBytes(&buf, std.math.inf(f64)));
    try expectBytes("f97e00", floatBytes(&buf, std.math.nan(f64)));
    try expectBytes("f9fc00", floatBytes(&buf, -std.math.inf(f64)));
    try expectBytes("fa3dcccccd", floatBytes(&buf, @as(f32, 0.1)));
}

test "a float reads back as the value written, whatever width it took" {
    var buf: [9]u8 = undefined;
    const values = [_]f64{ 65504.0, @as(f32, 0.1), 5.960464477539063e-8, 1.1, -4.0, 1.0e+300, -0.0, std.math.inf(f64) };
    for (values) |value| {
        const head = try readHead(floatBytes(&buf, value));
        try testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(floatValue(head))));
    }
    try testing.expect(std.math.isNan(floatValue(try readHead(floatBytes(&buf, std.math.nan(f64))))));
}

test "a head reads back as it was written, and a short or reserved one is refused" {
    var buf: [9]u8 = undefined;
    for ([_]u64{ 0, 23, 24, 255, 256, 65535, 65536, 0xFFFF_FFFF, 0x1_0000_0000, std.math.maxInt(u64) }) |argument| {
        const bytes = headBytes(&buf, .array, argument);
        const head = try readHead(bytes);
        try testing.expectEqual(Major.array, head.major);
        try testing.expectEqual(argument, head.argument);
        try testing.expectEqual(bytes.len, head.size);
    }
    try testing.expectError(error.Truncated, readHead(""));
    try testing.expectError(error.Truncated, readHead(&hex("1903")));
    try testing.expectError(error.Reserved, readHead(&hex("1c")));
    const open = try readHead(&hex("9f"));
    try testing.expectEqual(indefinite, open.info);
}

test "text that is not UTF-8 is written with U+FFFD in its place, as JSON text is" {
    var buf: [32]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try writeText(&out, "IETF");
    try expectBytes("6449455446", out.buffered());

    out = .fixed(&buf);
    try writeText(&out, "a\xffb");
    try expectBytes("6561efbfbd62", out.buffered());

    out = .fixed(&buf);
    try writeText(&out, "水\xed\xa0\x80");
    try expectBytes("6ce6b0b4efbfbdefbfbdefbfbd", out.buffered());
}
