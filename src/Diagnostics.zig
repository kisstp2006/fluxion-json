// SPDX-License-Identifier: CC0-1.0

//! Where reading went wrong and why, in words a person can act on. Pass one
//! in the options of any read, and print it with `{f}` when the read fails:
//!
//! ```
//! config.json:3:14: expected ',' or '}' after an object member
//!     "volume": 0.8
//!              ^
//! ```
//!
//! Everything is held inside the struct, so it can be copied and outlives
//! both the text and the file name it describes.

const std = @import("std");
const testing = std.testing;

const Diagnostics = @This();

/// 1-based. Zero when the problem has no place in text, as when a `Value`
/// already in memory is being converted.
line: u32 = 0,
column: u32 = 0,
/// Bytes from the start of the text.
offset: usize = 0,

message_len: u16 = 0,
path_len: u16 = 0,
file_len: u16 = 0,
snippet_len: u16 = 0,
caret: u16 = 0,
message_buf: [240]u8 = undefined,
path_buf: [240]u8 = undefined,
file_buf: [240]u8 = undefined,
snippet_buf: [120]u8 = undefined,

/// What went wrong.
pub fn message(d: *const Diagnostics) []const u8 {
    return d.message_buf[0..d.message_len];
}

/// Where in the document, as a JSON Pointer such as `/enemies/3/health`.
/// Empty for the document as a whole, and for mistakes in the text itself.
pub fn path(d: *const Diagnostics) []const u8 {
    return d.path_buf[0..d.path_len];
}

/// The file being read, when there was one.
pub fn file(d: *const Diagnostics) []const u8 {
    return d.file_buf[0..d.file_len];
}

/// The line of text the problem is on, cut down to fit around it.
pub fn sourceLine(d: *const Diagnostics) []const u8 {
    return d.snippet_buf[0..d.snippet_len];
}

pub fn format(d: Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (d.file_len > 0) {
        try w.print("{s}:{d}:{d}: ", .{ d.file(), d.line, d.column });
    } else if (d.line > 0) {
        try w.print("line {d}, column {d}: ", .{ d.line, d.column });
    }
    try w.writeAll(d.message());
    if (d.path_len > 0) try w.print(" (at {s})", .{d.path()});
    if (d.snippet_len == 0) return;
    const snippet = d.sourceLine();
    try w.print("\n    {s}\n    ", .{snippet});
    for (snippet[0..@min(d.caret, snippet.len)]) |c| {
        if (isContinuation(c)) continue;
        try w.writeByte(if (c == '\t') '\t' else ' ');
    }
    try w.writeByte('^');
}

pub const Location = struct {
    line: u32,
    column: u32,
};

/// The 1-based line and column of `offset` in `source`, counting columns in
/// characters. It reads from the start, so it costs as much as the offset is far.
pub fn locate(source: []const u8, offset: usize) Location {
    const before = source[0..@min(offset, source.len)];
    const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |i| i + 1 else 0;
    return .{
        .line = @intCast(std.mem.count(u8, before, "\n") + 1),
        .column = @intCast(codepoints(before[line_start..]) + 1),
    };
}

/// Point at `offset` in `source`: line, column and the text around it.
pub fn setPlace(d: *Diagnostics, source: []const u8, offset: usize) void {
    const at = @min(offset, source.len);
    const before = source[0..at];
    const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |i| i + 1 else 0;
    var line_end = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse source.len;
    if (line_end > line_start and source[line_end - 1] == '\r') line_end -= 1;

    const place = locate(source, at);
    d.offset = at;
    d.line = place.line;
    d.column = place.column;

    const room = d.snippet_buf.len - 6;
    var start = line_start;
    var end = line_end;
    if (end - start > room) {
        start = @max(line_start, if (at > room / 2) at - room / 2 else 0);
        while (start > line_start and isContinuation(source[start])) start -= 1;
        end = @min(line_end, start + room);
        while (end > start and end < line_end and isContinuation(source[end])) end -= 1;
    }
    var out: std.Io.Writer = .fixed(&d.snippet_buf);
    if (start > line_start) out.writeAll("...") catch {};
    const lead = out.end;
    out.writeAll(source[start..end]) catch {};
    if (end < line_end) out.writeAll("...") catch {};
    d.snippet_len = @intCast(out.end);
    d.caret = @intCast(lead + @min(at, end) - @min(start, at));
}

/// Clear the place, for a problem that has none.
pub fn setNoPlace(d: *Diagnostics) void {
    d.line = 0;
    d.column = 0;
    d.offset = 0;
    d.snippet_len = 0;
    d.caret = 0;
}

pub fn setMessage(d: *Diagnostics, comptime fmt: []const u8, args: anytype) void {
    d.message_len = @intCast(clipped(&d.message_buf, fmt, args).len);
}

pub fn setPath(d: *Diagnostics, text: []const u8) void {
    d.path_len = @intCast(clipped(&d.path_buf, "{s}", .{text}).len);
}

pub fn setFile(d: *Diagnostics, name: []const u8) void {
    d.file_len = @intCast(clipped(&d.file_buf, "{s}", .{name}).len);
}

/// Print into `buf`, and end with "..." if it did not all fit.
fn clipped(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print(fmt, args) catch {
        var keep = buf.len - 3;
        while (keep > 0 and isContinuation(buf[keep])) keep -= 1;
        @memcpy(buf[keep..][0..3], "...");
        return buf[0 .. keep + 3];
    };
    return w.buffered();
}

fn isContinuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

fn codepoints(bytes: []const u8) usize {
    var n: usize = 0;
    for (bytes) |byte| n += @intFromBool(!isContinuation(byte));
    return n;
}

fn expectPrinted(expected: []const u8, d: Diagnostics) !void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f}", .{d});
    try testing.expectEqualStrings(expected, w.buffered());
}

test "a place in the text becomes a line, a column and a caret" {
    const source = "{\n  \"volume\": 0.8\n  \"muted\": true\n}";
    var d: Diagnostics = .{};
    d.setPlace(source, std.mem.indexOf(u8, source, "\"muted\"").?);
    d.setMessage("expected ',' or '}}' after an object member", .{});
    try testing.expectEqual(@as(u32, 3), d.line);
    try testing.expectEqual(@as(u32, 3), d.column);
    try expectPrinted(
        \\line 3, column 3: expected ',' or '}' after an object member
        \\      "muted": true
        \\      ^
    , d);

    d.setFile("settings.json");
    d.setPath("/muted");
    try expectPrinted(
        \\settings.json:3:3: expected ',' or '}' after an object member (at /muted)
        \\      "muted": true
        \\      ^
    , d);
}

test "columns count characters, and tabs keep the caret under its place" {
    const source = "\t\"café\": x";
    var d: Diagnostics = .{};
    d.setPlace(source, std.mem.indexOfScalar(u8, source, 'x').?);
    d.setMessage("unexpected word", .{});
    try testing.expectEqual(@as(u32, 10), d.column);
    try expectPrinted("line 1, column 10: unexpected word\n    \t\"café\": x\n    \t        ^", d);
}

test "a long line is cut down to the part around the problem" {
    var source: [4000]u8 = undefined;
    @memset(&source, 'a');
    source[3000] = '!';
    var d: Diagnostics = .{};
    d.setPlace(&source, 3000);
    try testing.expectEqual(@as(u32, 3001), d.column);
    const snippet = d.sourceLine();
    try testing.expect(snippet.len <= d.snippet_buf.len);
    try testing.expect(std.mem.startsWith(u8, snippet, "..."));
    try testing.expect(std.mem.endsWith(u8, snippet, "..."));
    try testing.expectEqual(@as(u8, '!'), snippet[d.caret]);
}

test "the end of the text is a place too" {
    const source = "[1, 2";
    var d: Diagnostics = .{};
    d.setPlace(source, source.len);
    try testing.expectEqual(@as(u32, 6), d.column);
    try testing.expectEqual(@as(u16, 5), d.caret);
}

test "a message too long for its buffer ends in an ellipsis" {
    var d: Diagnostics = .{};
    d.setMessage("{s}", .{"x" ** 400});
    try testing.expectEqual(d.message_buf.len, d.message().len);
    try testing.expect(std.mem.endsWith(u8, d.message(), "..."));
}

test "a copy keeps its own text" {
    var d: Diagnostics = .{};
    d.setMessage("first", .{});
    const copy = d;
    d.setMessage("second", .{});
    try testing.expectEqualStrings("first", copy.message());
}
