// SPDX-License-Identifier: CC0-1.0

const std = @import("std");
const testing = std.testing;

/// The length of the valid UTF-8 character at the start of `bytes`, or null.
/// Overlong forms, surrogates and anything past U+10FFFF are not valid.
pub fn sequenceLength(bytes: []const u8) ?usize {
    const len: usize, const low: u8, const high: u8 = switch (bytes[0]) {
        0x00...0x7F => return 1,
        0xC2...0xDF => .{ 2, 0x80, 0xBF },
        0xE0 => .{ 3, 0xA0, 0xBF },
        0xE1...0xEC, 0xEE, 0xEF => .{ 3, 0x80, 0xBF },
        0xED => .{ 3, 0x80, 0x9F },
        0xF0 => .{ 4, 0x90, 0xBF },
        0xF1...0xF3 => .{ 4, 0x80, 0xBF },
        0xF4 => .{ 4, 0x80, 0x8F },
        else => return null,
    };
    if (bytes.len < len or bytes[1] < low or bytes[1] > high) return null;
    for (bytes[2..len]) |c| if (c & 0xC0 != 0x80) return null;
    return len;
}

/// The first index from `start` of a byte that a string cannot pass over
/// without a look: `quote`, a backslash, a control character or the first
/// byte of a multi-byte character. Sixteen bytes at a time while it can.
pub fn plainRun(bytes: []const u8, start: usize, quote: u8) usize {
    const V = @Vector(16, u8);
    var i = start;
    while (i + 16 <= bytes.len) : (i += 16) {
        const chunk: V = bytes[i..][0..16].*;
        const stop = (chunk == @as(V, @splat(quote))) | (chunk == @as(V, @splat('\\'))) |
            (chunk < @as(V, @splat(0x20))) | (chunk >= @as(V, @splat(0x80)));
        if (std.simd.firstTrue(stop)) |at| return i + at;
    }
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == quote or c == '\\' or c < 0x20 or c >= 0x80) return i;
    }
    return i;
}

/// How long `s` is once quoted and escaped by `writeQuoted`.
pub fn quotedLength(s: []const u8, ascii: bool) usize {
    var n: usize = 2 + s.len;
    var i: usize = 0;
    while (true) {
        i = plainRun(s, i, '"');
        if (i >= s.len) return n;
        const c = s[i];
        if (c < 0x80) {
            n += shortEscape(c).len - 1;
            i += 1;
            continue;
        }
        const len = sequenceLength(s[i..]) orelse {
            n += if (ascii) 5 else 2;
            i += 1;
            continue;
        };
        if (ascii) n += (if (len == 4) @as(usize, 12) else 6) - len;
        i += len;
    }
}

/// Write `s` as a JSON string: quoted, with `"`, `\` and control characters
/// escaped, and each byte that is not UTF-8 replaced with U+FFFD so the
/// result is always valid. `ascii` escapes everything past U+007F as well.
pub fn writeQuoted(out: *std.Io.Writer, s: []const u8, ascii: bool) std.Io.Writer.Error!void {
    try out.writeByte('"');
    var run: usize = 0;
    var i: usize = 0;
    while (true) {
        i = plainRun(s, i, '"');
        if (i >= s.len) break;
        const c = s[i];
        if (c < 0x80) {
            try out.writeAll(s[run..i]);
            const escaped = shortEscape(c);
            if (escaped.len == 2) try out.writeAll(escaped) else try out.print("\\u{x:0>4}", .{c});
            i += 1;
            run = i;
            continue;
        }
        const len = sequenceLength(s[i..]) orelse {
            try out.writeAll(s[run..i]);
            try out.writeAll(if (ascii) "\\ufffd" else "\u{FFFD}");
            i += 1;
            run = i;
            continue;
        };
        if (ascii) {
            try out.writeAll(s[run..i]);
            const cp = std.unicode.utf8Decode(s[i..][0..len]) catch unreachable;
            if (cp >= 0x10000) {
                const offset = cp - 0x10000;
                try out.print("\\u{x:0>4}\\u{x:0>4}", .{ 0xD800 + (offset >> 10), 0xDC00 + (offset & 0x3FF) });
            } else try out.print("\\u{x:0>4}", .{cp});
            run = i + len;
        }
        i += len;
    }
    try out.writeAll(s[run..]);
    try out.writeByte('"');
}

/// What an ASCII byte becomes: one byte for itself, a two-character escape,
/// or a placeholder as long as the `\u00XX` escape it needs.
fn shortEscape(c: u8) []const u8 {
    return switch (c) {
        '"' => "\\\"",
        '\\' => "\\\\",
        '\n' => "\\n",
        '\r' => "\\r",
        '\t' => "\\t",
        0x08 => "\\b",
        0x0C => "\\f",
        0x00...0x07, 0x0B, 0x0E...0x1F => "\\u0000",
        else => "?",
    };
}

fn expectQuoted(expected: []const u8, s: []const u8, ascii: bool) !void {
    var buf: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try writeQuoted(&out, s, ascii);
    try testing.expectEqualStrings(expected, out.buffered());
    try testing.expectEqual(expected.len, quotedLength(s, ascii));
}

test "quoting escapes what JSON requires and nothing more" {
    try expectQuoted("\"plain\"", "plain", false);
    try expectQuoted("\"a\\\"b\\\\c\"", "a\"b\\c", false);
    try expectQuoted("\"\\n\\r\\t\\b\\f\\u0001\\u001f\"", "\n\r\t\x08\x0c\x01\x1f", false);
    try expectQuoted("\"/ stays /\"", "/ stays /", false);
    try expectQuoted("\"café 中 😀\"", "café 中 😀", false);
}

test "ascii escapes everything past U+007F, astral characters as surrogate pairs" {
    try expectQuoted("\"caf\\u00e9 \\u4e2d \\ud83d\\ude00\"", "café 中 😀", true);
}

test "bytes that are not UTF-8 become U+FFFD" {
    try expectQuoted("\"a\u{FFFD}b\"", "a\xffb", false);
    try expectQuoted("\"a\\ufffdb\"", "a\xffb", true);
    try expectQuoted("\"\u{FFFD}\u{FFFD}\u{FFFD}\"", "\xed\xa0\x80", false);
    try expectQuoted("\"\u{FFFD}\"", "\xe4", false);
}

test "sequenceLength refuses overlong forms, surrogates and past U+10FFFF" {
    try testing.expectEqual(@as(?usize, 2), sequenceLength("é"));
    try testing.expectEqual(@as(?usize, 4), sequenceLength("😀"));
    try testing.expectEqual(@as(?usize, null), sequenceLength("\xc0\xaf"));
    try testing.expectEqual(@as(?usize, null), sequenceLength("\xe0\x80\xaf"));
    try testing.expectEqual(@as(?usize, null), sequenceLength("\xed\xa0\x80"));
    try testing.expectEqual(@as(?usize, null), sequenceLength("\xf4\x90\x80\x80"));
    try testing.expectEqual(@as(?usize, null), sequenceLength("\xe4\xb8"));
}
