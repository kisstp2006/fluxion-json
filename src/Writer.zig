// SPDX-License-Identifier: CC0-1.0

//! JSON written a piece at a time into a `std.Io.Writer`, as text or as
//! CBOR.
//!
//! ```zig
//! var writer: json.Writer = .init(out, .{ .indent = 2 });
//! try writer.beginObject();
//! try writer.field("name", "Ada");
//! try writer.key("scores");
//! try writer.write(&[_]u32{ 90, 85 });
//! try writer.endObject();
//! ```
//!
//! Indented output is laid out, not just broken into lines: an object or an
//! array that fits on one line stays on one, `"position": { "x": 1.0, "y": 2.0 }`,
//! and a long list of plain values is wrapped at the line width instead of
//! taking a line for every number.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const number = @import("number.zig");
const Number = number.Number;
const utf8 = @import("utf8.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Builder = value_mod.Builder;
const encode = @import("encode.zig");
const Reader = @import("Reader.zig");
const cbor = @import("cbor.zig");

const Writer = @This();

pub const Format = Reader.Format;

pub const Options = struct {
    /// `.cbor` writes CBOR (RFC 8949) rather than text: the same values in
    /// fewer bytes. The layout options do not apply to it; `sort_keys`,
    /// `skip_nulls`, `skip_defaults` and `non_finite` do.
    format: Format = .json,
    /// Spaces for each level of nesting. 0 writes everything on one line and
    /// without spaces, as `JSON.stringify` does without its third argument.
    indent: u8 = 0,
    /// Indent with a tab for each level rather than spaces. Takes effect
    /// when `indent` is not 0.
    use_tabs: bool = false,
    /// With `indent`, an object or array that fits in this many columns
    /// stays on one line, and a list of plain values too long for one line is
    /// wrapped at it. 0 puts every item on its own line, as JavaScript does.
    /// At most 240.
    line_width: u16 = 80,
    /// Write every object's members in alphabetical order, as Python's
    /// `sort_keys` does. A Zig hash map has no order of its own and is
    /// always written sorted.
    sort_keys: bool = false,
    /// Write every character past ASCII as a `\u` escape.
    escape_unicode: bool = false,
    /// Leave out struct fields that are `null`.
    skip_nulls: bool = false,
    /// Leave out struct fields that hold their default value, so a settings
    /// file lists only what was changed.
    skip_defaults: bool = false,
    /// What NaN and infinity become, since JSON has no number for them. In
    /// CBOR, `.literal` writes them as the floats they are.
    non_finite: NonFinite = .null,
};

pub const NonFinite = enum {
    /// `null`, as JavaScript writes them.
    null,
    /// `NaN`, `Infinity` and `-Infinity`, as JSON5 and Python write them.
    literal,
    /// Refuse with `error.NonFiniteNumber`.
    fail,
};

pub const Error = error{ WriteFailed, OutOfMemory, TooDeep, NonFiniteNumber };

options: Options,
target: Target,
/// How many objects and arrays are open.
depth: u16 = 0,
objects: [Reader.max_depth_limit / 64]u64 = @splat(0),
first: bool = true,
awaiting_value: bool = false,
layout: Layout = .{},
/// Whether the CBOR self-described tag has gone out, ahead of the value.
tagged: bool = false,

const Target = union(enum) { text: *std.Io.Writer, tree: *Builder, cbor: *std.Io.Writer };
const max_line_width = 240;
const tab_columns = 4;

pub fn init(out: *std.Io.Writer, options: Options) Writer {
    return .{
        .options = options,
        .target = if (options.format == .cbor) .{ .cbor = out } else .{ .text = out },
    };
}

/// A writer that builds a `Value` tree rather than text.
pub fn initTree(builder: *Builder) Writer {
    return .{ .options = .{}, .target = .{ .tree = builder } };
}

pub fn beginObject(w: *Writer) Error!void {
    return w.open(true);
}

pub fn endObject(w: *Writer) Error!void {
    return w.close(true);
}

pub fn beginArray(w: *Writer) Error!void {
    return w.open(false);
}

pub fn endArray(w: *Writer) Error!void {
    return w.close(false);
}

/// The name of the next object member. Its value comes next.
pub fn key(w: *Writer, name: []const u8) Error!void {
    assert(w.inObject() and !w.awaiting_value);
    switch (w.target) {
        .tree => |b| try b.key(name),
        .cbor => |out| try cbor.writeText(out, name),
        .text => |out| if (w.options.indent == 0) {
            if (!w.first) try out.writeByte(',');
            w.first = false;
            try utf8.writeQuoted(out, name, w.options.escape_unicode);
            try out.writeByte(':');
        } else try w.prettyKey(out, name),
    }
    w.awaiting_value = true;
}

/// Any value: a `Value`, or a Zig value of any type JSON can hold. See
/// `json.stringify` for how each type is written.
pub fn write(w: *Writer, value: anytype) Error!void {
    return encode.write(w, value);
}

/// A key and its value.
pub fn field(w: *Writer, name: []const u8, value: anytype) Error!void {
    try w.key(name);
    try w.write(value);
}

pub fn writeNull(w: *Writer) Error!void {
    switch (w.target) {
        .tree => |b| try b.add(.null),
        .text => |out| try w.textScalar(out, .{ .raw = "null" }),
        .cbor => |out| try w.cborScalar(out, &.{0xF6}),
    }
    w.afterScalar();
}

pub fn writeBool(w: *Writer, b: bool) Error!void {
    switch (w.target) {
        .tree => |builder| try builder.add(.{ .bool = b }),
        .text => |out| try w.textScalar(out, .{ .raw = if (b) "true" else "false" }),
        .cbor => |out| try w.cborScalar(out, &.{if (b) 0xF5 else 0xF4}),
    }
    w.afterScalar();
}

pub fn writeString(w: *Writer, s: []const u8) Error!void {
    switch (w.target) {
        .tree => |b| try b.string(s),
        .text => |out| try w.textScalar(out, .{ .string = s }),
        .cbor => |out| {
            try w.cborStart(out);
            try cbor.writeText(out, s);
        },
    }
    w.afterScalar();
}

/// An integer of any width, written in full. In CBOR one past what it holds,
/// -2^64 to 2^64 - 1, is written as a float, as a tree holds one past i64.
pub fn writeInt(w: *Writer, value: anytype) Error!void {
    switch (w.target) {
        .tree => |b| try b.add(if (std.math.cast(i64, value)) |i| .{ .int = i } else .{ .float = @floatFromInt(value) }),
        .text => |out| {
            var buf: [number.maxIntLen(@TypeOf(value)) + 1]u8 = undefined;
            const digits = number.formatInt(&buf, value);
            if (w.options.indent == 0) {
                try w.compactRaw(out, &buf, buf.len - digits.len);
            } else try w.prettyValue(out, .{ .raw = digits });
        },
        .cbor => |out| {
            const head = cbor.intHead(value) orelse return w.writeFloat(@as(f64, @floatFromInt(value)));
            try w.cborStart(out);
            try cbor.writeHead(out, head.major, head.argument);
        },
    }
    w.afterScalar();
}

/// A float of any width, in the fewest digits that read back as it - or in
/// CBOR, the fewest bytes.
pub fn writeFloat(w: *Writer, value: anytype) Error!void {
    switch (w.target) {
        .tree => |b| try b.add(.{ .float = faithful(value) }),
        .text => |out| {
            if (std.math.isFinite(value)) {
                var buf: [number.max_float_len + 1]u8 = undefined;
                const text = number.formatFloat(buf[1..], value);
                if (w.options.indent == 0) {
                    try w.compactRaw(out, buf[0 .. text.len + 1], 1);
                } else try w.prettyValue(out, .{ .raw = text });
            } else switch (w.options.non_finite) {
                .null => try w.textScalar(out, .{ .raw = "null" }),
                .literal => try w.textScalar(out, .{ .raw = if (std.math.isNan(value)) "NaN" else if (value > 0) "Infinity" else "-Infinity" }),
                .fail => return error.NonFiniteNumber,
            }
        },
        .cbor => |out| {
            if (std.math.isFinite(value) or w.options.non_finite == .literal) {
                try w.cborStart(out);
                try cbor.writeFloat(out, value);
            } else if (w.options.non_finite == .null) {
                try w.cborScalar(out, &.{0xF6});
            } else return error.NonFiniteNumber;
        },
    }
    w.afterScalar();
}

/// A number from a `Reader`, as it was written if that is valid JSON, and
/// converted if it is JSON5 that JSON would not accept.
pub fn writeNumber(w: *Writer, n: Number) Error!void {
    switch (w.target) {
        .tree => |b| {
            try b.add(value_mod.numberValue(n));
            w.afterScalar();
        },
        .cbor => {
            if (n.isInteger()) {
                if (n.asInt(i128)) |i| return w.writeInt(i);
            }
            return w.writeFloat(n.asFloat(f64));
        },
        .text => |out| {
            if (!number.isJson(n.text)) {
                if (n.isInteger()) {
                    if (n.asInt(i128)) |i| return w.writeInt(i);
                }
                return w.writeFloat(n.asFloat(f64));
            }
            try w.textScalar(out, .{ .raw = n.text });
            w.afterScalar();
        },
    }
}

/// A float of any width as the f64 nearest its shortest decimal form, so an
/// f32 0.1 becomes the f64 0.1 and not 0.10000000149011612.
fn faithful(value: anytype) f64 {
    const T = @TypeOf(value);
    if (T == f64) return value;
    if (@bitSizeOf(T) > 64 or !std.math.isFinite(value)) return @floatCast(value);
    var buf: [number.max_float_len]u8 = undefined;
    return std.fmt.parseFloat(f64, number.formatFloat(&buf, value)) catch unreachable;
}

fn afterScalar(w: *Writer) void {
    w.awaiting_value = false;
    w.first = false;
}

/// The self-described tag, once, ahead of the value: what tells a reader
/// these bytes are CBOR.
fn cborStart(w: *Writer, out: *std.Io.Writer) Error!void {
    assert(!w.inObject() or w.awaiting_value);
    if (w.tagged) return;
    w.tagged = true;
    try out.writeAll(&cbor.self_described);
}

fn cborScalar(w: *Writer, out: *std.Io.Writer, bytes: []const u8) Error!void {
    try w.cborStart(out);
    try out.writeAll(bytes);
}

fn open(w: *Writer, is_object: bool) Error!void {
    assert(!w.inObject() or w.awaiting_value);
    if (w.depth >= Reader.max_depth_limit) return error.TooDeep;
    switch (w.target) {
        .tree => |b| try b.begin(is_object, 0),
        // The length is not known yet, so the container is closed by a break.
        .cbor => |out| {
            try w.cborStart(out);
            try out.writeByte(@as(u8, if (is_object) 0xBF else 0x9F));
        },
        .text => |out| if (w.options.indent == 0) {
            try w.compactSeparator(out);
            try out.writeByte(if (is_object) '{' else '[');
        } else try w.prettyOpen(out, is_object),
    }
    w.awaiting_value = false;
    const bit = @as(u64, 1) << @intCast(w.depth % 64);
    if (is_object) w.objects[w.depth / 64] |= bit else w.objects[w.depth / 64] &= ~bit;
    w.depth += 1;
    w.first = true;
}

fn close(w: *Writer, is_object: bool) Error!void {
    assert(w.depth > 0 and w.inObject() == is_object and !w.awaiting_value);
    switch (w.target) {
        .tree => |b| b.end() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateKey => unreachable,
        },
        .cbor => |out| try out.writeByte(cbor.break_byte),
        .text => |out| if (w.options.indent == 0) {
            try out.writeByte(if (is_object) '}' else ']');
        } else try w.prettyClose(out),
    }
    w.depth -= 1;
    w.first = false;
}

fn inObject(w: *const Writer) bool {
    if (w.depth == 0) return false;
    const level = w.depth - 1;
    return w.objects[level / 64] & (@as(u64, 1) << @intCast(level % 64)) != 0;
}

fn lineWidth(w: *const Writer) usize {
    return @min(w.options.line_width, max_line_width);
}

const Piece = union(enum) {
    raw: []const u8,
    string: []const u8,

    fn length(p: Piece, ascii: bool) usize {
        return switch (p) {
            .raw => |r| r.len,
            .string => |s| utf8.quotedLength(s, ascii),
        };
    }

    fn put(p: Piece, out: *std.Io.Writer, ascii: bool) std.Io.Writer.Error!void {
        switch (p) {
            .raw => |r| try out.writeAll(r),
            .string => |s| try utf8.writeQuoted(out, s, ascii),
        }
    }
};

fn textScalar(w: *Writer, out: *std.Io.Writer, piece: Piece) Error!void {
    assert(!w.inObject() or w.awaiting_value);
    if (w.options.indent == 0) {
        try w.compactSeparator(out);
        return piece.put(out, w.options.escape_unicode);
    }
    return w.prettyValue(out, piece);
}

fn compactSeparator(w: *Writer, out: *std.Io.Writer) Error!void {
    if (w.awaiting_value) return;
    if (w.depth > 0 and !w.first) try out.writeByte(',');
}

/// `buf[start..]` with the comma before it, if one is due, in one write:
/// `buf[start - 1]` is free for it.
fn compactRaw(w: *Writer, out: *std.Io.Writer, buf: []u8, start: usize) Error!void {
    assert(!w.inObject() or w.awaiting_value);
    if (!w.awaiting_value and w.depth > 0 and !w.first) {
        buf[start - 1] = ',';
        return out.writeAll(buf[start - 1 ..]);
    }
    return out.writeAll(buf[start..]);
}

/// How indented output is laid out. Containers already written with an item
/// to a line (`expanded`), or wrapped line by line (`filled`), are a stack
/// whose innermost level is described here. The innermost container still
/// undecided is held back: what goes into it is kept as events, with its one
/// line width counted as they come, until it closes and is written on one
/// line, or grows too wide and is written out after all - at which point
/// what was held is played back through the same rules, so a container
/// inside it gets its own chance at one line, from where it now starts.
const Layout = struct {
    column: usize = 0,
    depth: u16 = 0,
    objects: [Reader.max_depth_limit / 64]u64 = @splat(0),
    style: Style = .expanded,
    first: bool = true,
    after_key: bool = false,

    holding: bool = false,
    held_at: usize = 0,
    events: [max_events]Event = undefined,
    event_count: u16 = 0,
    text: [text_capacity]u8 = undefined,
    text_len: u16 = 0,
    levels: [max_events + 1]Level = undefined,
    level_count: u16 = 0,
    width: usize = 0,

    const Style = enum { expanded, filled };
    const max_events = 128;
    const text_capacity = 256;
};

const Event = struct { kind: Kind, start: u16 = 0, len: u16 = 0 };
const Kind = enum(u8) { object, array, close, key, value };
const Level = struct { is_object: bool, first: bool = true, after_key: bool = false };

fn prettyOpen(w: *Writer, out: *std.Io.Writer, is_object: bool) Error!void {
    if (w.layout.holding) {
        if (w.hold(if (is_object) .object else .array, 0)) {
            if (w.heldFits()) return;
            return w.unfold(out);
        }
        try w.unfold(out);
        return w.prettyOpen(out, is_object);
    }
    try w.lineOpen(out, is_object);
}

fn prettyClose(w: *Writer, out: *std.Io.Writer) Error!void {
    const l = &w.layout;
    if (l.holding) {
        if (w.hold(.close, 0)) {
            if (l.level_count > 0) {
                if (w.heldFits()) return;
                return w.unfold(out);
            }
            if (l.held_at + l.width + 1 < w.lineWidth()) {
                _ = try w.walkLine(out, l.events[0..l.event_count], l.levels[0].is_object);
                l.column += l.width;
                l.holding = false;
                l.event_count = 0;
                l.text_len = 0;
                return;
            }
            return w.unfold(out);
        }
        try w.unfold(out);
        return w.prettyClose(out);
    }
    try w.lineClose(out);
}

fn prettyKey(w: *Writer, out: *std.Io.Writer, name: []const u8) Error!void {
    const l = &w.layout;
    const ascii = w.options.escape_unicode;
    const len = w.stage(.{ .string = name }) orelse {
        if (l.holding) {
            try w.unfold(out);
            return w.prettyKey(out, name);
        }
        try w.linePrefix(out, 0);
        try utf8.writeQuoted(out, name, ascii);
        try out.writeAll(": ");
        l.column += utf8.quotedLength(name, ascii) + 2;
        l.after_key = true;
        return;
    };
    if (l.holding) {
        if (w.hold(.key, len)) {
            if (w.heldFits()) return;
            return w.unfold(out);
        }
        try w.unfold(out);
        return w.prettyKey(out, name);
    }
    try w.lineKey(out, l.text[l.text_len..][0..len]);
}

fn prettyValue(w: *Writer, out: *std.Io.Writer, piece: Piece) Error!void {
    const l = &w.layout;
    const ascii = w.options.escape_unicode;
    if (!l.holding) {
        if (l.depth == 0 or l.style == .expanded) {
            try w.linePrefix(out, 0);
            return piece.put(out, ascii);
        }
        if (piece == .raw) return w.lineValue(out, piece.raw);
        if (w.stage(piece)) |len| return w.lineValue(out, l.text[l.text_len..][0..len]);
        const n = piece.length(ascii);
        try w.linePrefix(out, n);
        try piece.put(out, ascii);
        l.column += n;
        return;
    }
    if (w.stage(piece)) |len| {
        if (w.hold(.value, len)) {
            if (w.heldFits()) return;
            return w.unfold(out);
        }
    }
    try w.unfold(out);
    return w.prettyValue(out, piece);
}

/// Escape `piece` into the text buffer after what is held there, without
/// keeping it: its length, or null if it does not fit.
fn stage(w: *Writer, piece: Piece) ?usize {
    const room = w.layout.text[w.layout.text_len..];
    switch (piece) {
        .raw => |r| {
            if (r.len > room.len) return null;
            @memcpy(room[0..r.len], r);
            return r.len;
        },
        .string => |s| {
            if (s.len + 2 <= room.len and utf8.plainRun(s, 0, '"') == s.len) {
                room[0] = '"';
                @memcpy(room[1..][0..s.len], s);
                room[s.len + 1] = '"';
                return s.len + 2;
            }
            var sink: std.Io.Writer = .fixed(room);
            utf8.writeQuoted(&sink, s, w.options.escape_unicode) catch return null;
            return sink.end;
        },
    }
}

/// Keep an event, whose text is already staged, and count what it adds to
/// the held container's width on one line. False if there is no room.
fn hold(w: *Writer, kind: Kind, len: usize) bool {
    const l = &w.layout;
    if (l.event_count == Layout.max_events) return false;
    l.events[l.event_count] = .{ .kind = kind, .start = l.text_len, .len = @intCast(len) };
    l.event_count += 1;
    l.text_len += @intCast(len);
    w.measure(kind, len);
    return true;
}

fn measure(w: *Writer, kind: Kind, len: usize) void {
    const l = &w.layout;
    const top = &l.levels[l.level_count - 1];
    switch (kind) {
        .key => {
            l.width += @as(usize, if (top.first) 1 else 2) + len + 2;
            top.first = false;
            top.after_key = true;
        },
        .value, .object, .array => {
            if (top.after_key) {
                top.after_key = false;
            } else {
                if (!top.first) l.width += 2;
                top.first = false;
            }
            if (kind == .value) {
                l.width += len;
            } else {
                l.width += 1;
                l.levels[l.level_count] = .{ .is_object = kind == .object };
                l.level_count += 1;
            }
        },
        .close => {
            l.level_count -= 1;
            const closed = l.levels[l.level_count];
            l.width += if (closed.is_object and !closed.first) 2 else 1;
        },
    }
}

/// Whether the held container, closed as it stands, still fits on its line
/// with room for a comma after it.
fn heldFits(w: *const Writer) bool {
    const l = &w.layout;
    var closers: usize = 0;
    for (l.levels[0..l.level_count]) |level| closers += if (level.is_object and !level.first) 2 else 1;
    return l.held_at + l.width + closers + 1 < w.lineWidth();
}

/// One line's worth of held events: written to `out` if there is one, and
/// measured either way.
fn walkLine(w: *Writer, out: ?*std.Io.Writer, events: []const Event, is_object: bool) Error!usize {
    var levels: [Layout.max_events + 1]Level = undefined;
    levels[0] = .{ .is_object = is_object };
    var count: usize = 1;
    var width: usize = 0;
    for (events) |e| {
        const top = &levels[count - 1];
        var parts: [3][]const u8 = .{ "", "", "" };
        switch (e.kind) {
            .key => {
                parts = .{ if (top.first) " " else ", ", w.layout.text[e.start..][0..e.len], ": " };
                top.first = false;
                top.after_key = true;
            },
            .value, .object, .array => {
                if (top.after_key) {
                    top.after_key = false;
                } else {
                    if (!top.first) parts[0] = ", ";
                    top.first = false;
                }
                parts[1] = switch (e.kind) {
                    .value => w.layout.text[e.start..][0..e.len],
                    .object => "{",
                    else => "[",
                };
                if (e.kind != .value) {
                    levels[count] = .{ .is_object = e.kind == .object };
                    count += 1;
                }
            },
            .close => {
                count -= 1;
                const closed = levels[count];
                parts[1] = if (!closed.is_object) "]" else if (closed.first) "}" else " }";
            },
        }
        for (parts) |part| {
            width += part.len;
            if (out) |o| try o.writeAll(part);
        }
    }
    return width;
}

/// The held container does not fit on one line: write it out after all,
/// and play back what was held into it.
fn unfold(w: *Writer, out: *std.Io.Writer) Error!void {
    const l = &w.layout;
    l.holding = false;
    const is_object = l.levels[0].is_object;
    w.pushLine(is_object, if (!is_object and !hasContainer(l.events[0..l.event_count])) .filled else .expanded);
    var i: usize = 0;
    while (i < l.event_count) : (i += 1) {
        const e = l.events[i];
        switch (e.kind) {
            .key => try w.lineKey(out, l.text[e.start..][0..e.len]),
            .value => try w.lineValue(out, l.text[e.start..][0..e.len]),
            .close => try w.lineClose(out),
            .object, .array => {
                const inner_is_object = e.kind == .object;
                if (l.style == .filled) l.style = .expanded;
                try w.linePrefix(out, 1);
                try out.writeByte(if (inner_is_object) '{' else '[');
                l.column += 1;
                const end = matchingClose(l.events[0..l.event_count], i) orelse {
                    w.holdFrom(i + 1, inner_is_object);
                    if (!w.heldFits()) return w.unfold(out);
                    return;
                };
                const inner = l.events[i + 1 .. end + 1];
                const width = try w.walkLine(null, inner, inner_is_object);
                if (l.column + width + 1 < w.lineWidth()) {
                    _ = try w.walkLine(out, inner, inner_is_object);
                    l.column += width;
                    i = end;
                } else {
                    w.pushLine(inner_is_object, if (!inner_is_object and !hasContainer(inner[0 .. inner.len - 1])) .filled else .expanded);
                }
            },
        }
    }
    l.event_count = 0;
    l.text_len = 0;
}

/// Hold back, as the undecided container, the events from `from` on: the
/// inside of a container whose opener has just been written.
fn holdFrom(w: *Writer, from: usize, is_object: bool) void {
    const l = &w.layout;
    const kept = l.event_count - from;
    const text_from = if (kept > 0) l.events[from].start else l.text_len;
    std.mem.copyForwards(u8, l.text[0 .. l.text_len - text_from], l.text[text_from..l.text_len]);
    std.mem.copyForwards(Event, l.events[0..kept], l.events[from..l.event_count]);
    l.text_len -= text_from;
    l.event_count = @intCast(kept);
    w.startHolding(is_object);
    for (l.events[0..kept]) |*e| {
        e.start -= text_from;
        w.measure(e.kind, e.len);
    }
}

fn startHolding(w: *Writer, is_object: bool) void {
    const l = &w.layout;
    l.holding = true;
    l.held_at = l.column;
    l.levels[0] = .{ .is_object = is_object };
    l.level_count = 1;
    l.width = 0;
}

fn hasContainer(events: []const Event) bool {
    for (events) |e| if (e.kind == .object or e.kind == .array) return true;
    return false;
}

fn matchingClose(events: []const Event, open_at: usize) ?usize {
    var nesting: usize = 0;
    for (events[open_at..], open_at..) |e, i| switch (e.kind) {
        .object, .array => nesting += 1,
        .close => {
            nesting -= 1;
            if (nesting == 0) return i;
        },
        else => {},
    };
    return null;
}

fn lineOpen(w: *Writer, out: *std.Io.Writer, is_object: bool) Error!void {
    const l = &w.layout;
    if (l.style == .filled) l.style = .expanded;
    try w.linePrefix(out, 1);
    try out.writeByte(if (is_object) '{' else '[');
    l.column += 1;
    l.event_count = 0;
    l.text_len = 0;
    if (w.lineWidth() > 0) w.startHolding(is_object) else w.pushLine(is_object, .expanded);
}

fn lineKey(w: *Writer, out: *std.Io.Writer, quoted: []const u8) Error!void {
    try w.linePrefix(out, 0);
    try out.writeAll(quoted);
    try out.writeAll(": ");
    w.layout.column += quoted.len + 2;
    w.layout.after_key = true;
}

fn lineValue(w: *Writer, out: *std.Io.Writer, text: []const u8) Error!void {
    try w.linePrefix(out, text.len);
    try out.writeAll(text);
    w.layout.column += text.len;
}

fn lineClose(w: *Writer, out: *std.Io.Writer) Error!void {
    const l = &w.layout;
    l.depth -= 1;
    const is_object = l.objects[l.depth / 64] & (@as(u64, 1) << @intCast(l.depth % 64)) != 0;
    if (!l.first) try w.newline(out, l.depth);
    try out.writeByte(if (is_object) '}' else ']');
    l.column += 1;
    l.style = .expanded;
    l.first = false;
    l.after_key = false;
}

fn pushLine(w: *Writer, is_object: bool, style: Layout.Style) void {
    const l = &w.layout;
    const bit = @as(u64, 1) << @intCast(l.depth % 64);
    if (is_object) l.objects[l.depth / 64] |= bit else l.objects[l.depth / 64] &= ~bit;
    l.depth += 1;
    l.style = style;
    l.first = true;
    l.after_key = false;
}

/// What goes before an item of the innermost written container: nothing
/// after a key, a comma and a new line, or in a filled one a comma and a
/// space while the line has room for `len` more.
fn linePrefix(w: *Writer, out: *std.Io.Writer, len: usize) Error!void {
    const l = &w.layout;
    if (l.depth == 0) return;
    if (l.after_key) {
        l.after_key = false;
        return;
    }
    switch (l.style) {
        .expanded => {
            if (!l.first) try out.writeByte(',');
            try w.newline(out, l.depth);
        },
        .filled => {
            if (l.first) {
                try w.newline(out, l.depth);
            } else if (l.column + 2 + len + 1 <= w.lineWidth()) {
                try out.writeAll(", ");
                l.column += 2;
            } else {
                try out.writeByte(',');
                try w.newline(out, l.depth);
            }
        },
    }
    l.first = false;
}

fn newline(w: *Writer, out: *std.Io.Writer, level: usize) Error!void {
    try out.writeByte('\n');
    if (w.options.use_tabs) {
        try out.splatByteAll('\t', level);
        w.layout.column = level * tab_columns;
    } else {
        try out.splatByteAll(' ', level * w.options.indent);
        w.layout.column = level * w.options.indent;
    }
}

fn expectWritten(options: Options, expected: []const u8, comptime build: fn (*Writer) Error!void) !void {
    var buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var writer: Writer = .init(&out, options);
    try build(&writer);
    try testing.expectEqualStrings(expected, out.buffered());
}

fn sample(w: *Writer) Error!void {
    try w.beginObject();
    try w.key("name");
    try w.writeString("Ada");
    try w.key("pos");
    try w.beginObject();
    try w.key("x");
    try w.writeFloat(@as(f32, 1.5));
    try w.key("y");
    try w.writeFloat(@as(f32, -2));
    try w.endObject();
    try w.key("tags");
    try w.beginArray();
    try w.endArray();
    try w.key("inventory");
    try w.beginArray();
    try w.beginObject();
    try w.key("item");
    try w.writeString("sword");
    try w.key("count");
    try w.writeInt(@as(u8, 1));
    try w.endObject();
    try w.writeNull();
    try w.endArray();
    try w.key("alive");
    try w.writeBool(true);
    try w.endObject();
}

test "compact output has no spaces at all" {
    try expectWritten(.{},
        \\{"name":"Ada","pos":{"x":1.5,"y":-2.0},"tags":[],"inventory":[{"item":"sword","count":1},null],"alive":true}
    , sample);
}

test "indented output keeps on one line whatever fits there" {
    try expectWritten(.{ .indent = 2 },
        \\{
        \\  "name": "Ada",
        \\  "pos": { "x": 1.5, "y": -2.0 },
        \\  "tags": [],
        \\  "inventory": [{ "item": "sword", "count": 1 }, null],
        \\  "alive": true
        \\}
    , sample);
    try expectWritten(.{ .indent = 2, .line_width = 140 },
        \\{ "name": "Ada", "pos": { "x": 1.5, "y": -2.0 }, "tags": [], "inventory": [{ "item": "sword", "count": 1 }, null], "alive": true }
    , sample);
}

test "a line width of zero puts every item on its own line, as JavaScript does" {
    try expectWritten(.{ .indent = 4, .line_width = 0 },
        \\{
        \\    "name": "Ada",
        \\    "pos": {
        \\        "x": 1.5,
        \\        "y": -2.0
        \\    },
        \\    "tags": [],
        \\    "inventory": [
        \\        {
        \\            "item": "sword",
        \\            "count": 1
        \\        },
        \\        null
        \\    ],
        \\    "alive": true
        \\}
    , sample);
}

test "tabs indent a level each" {
    try expectWritten(.{ .indent = 1, .use_tabs = true, .line_width = 0 }, "[\n\t[\n\t\t1\n\t]\n]", struct {
        fn build(w: *Writer) Error!void {
            try w.beginArray();
            try w.beginArray();
            try w.writeInt(@as(u8, 1));
            try w.endArray();
            try w.endArray();
        }
    }.build);
}

test "a long list of numbers is wrapped at the line width" {
    try expectWritten(.{ .indent = 2, .line_width = 40 },
        \\{
        \\  "tiles": [
        \\    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
        \\    11, 12, 13, 14, 15, 16, 17, 18, 19
        \\  ],
        \\  "rows": [[0, 1], [2, 3]]
        \\}
    , struct {
        fn build(w: *Writer) Error!void {
            try w.beginObject();
            try w.key("tiles");
            try w.beginArray();
            for (0..20) |i| try w.writeInt(i);
            try w.endArray();
            try w.key("rows");
            try w.beginArray();
            for (0..2) |row| {
                try w.beginArray();
                try w.writeInt(row * 2);
                try w.writeInt(row * 2 + 1);
                try w.endArray();
            }
            try w.endArray();
            try w.endObject();
        }
    }.build);
}

test "an object too wide for one line gets a line per member" {
    try expectWritten(.{ .indent = 2, .line_width = 30 },
        \\{
        \\  "name": "Ada Lovelace",
        \\  "title": "Countess"
        \\}
    , struct {
        fn build(w: *Writer) Error!void {
            try w.beginObject();
            try w.field("name", "Ada Lovelace");
            try w.field("title", "Countess");
            try w.endObject();
        }
    }.build);
}

test "a container that does not fit is opened out, and what is inside it gets its own chance" {
    try expectWritten(.{ .indent = 2, .line_width = 12 },
        \\[
        \\  1,
        \\  "two",
        \\  [3],
        \\  4
        \\]
    , struct {
        fn build(w: *Writer) Error!void {
            try w.beginArray();
            try w.writeInt(@as(u8, 1));
            try w.writeString("two");
            try w.beginArray();
            try w.writeInt(@as(u8, 3));
            try w.endArray();
            try w.writeInt(@as(u8, 4));
            try w.endArray();
        }
    }.build);
    try expectWritten(.{ .indent = 2, .line_width = 40 },
        \\[
        \\  { "type": "tree", "at": [3, 4] },
        \\  {
        \\    "type": "rock",
        \\    "at": [5, 6],
        \\    "tags": ["heavy", "grey", "old"]
        \\  },
        \\  { "type": "bush", "at": [7, 8] }
        \\]
    , struct {
        fn build(w: *Writer) Error!void {
            try w.beginArray();
            try w.write(.{ .type = "tree", .at = .{ 3, 4 } });
            try w.write(.{ .type = "rock", .at = .{ 5, 6 }, .tags = .{ "heavy", "grey", "old" } });
            try w.write(.{ .type = "bush", .at = .{ 7, 8 } });
            try w.endArray();
        }
    }.build);
}

test "non-finite floats follow the option" {
    const build = struct {
        fn build(w: *Writer) Error!void {
            try w.beginArray();
            try w.writeFloat(std.math.nan(f64));
            try w.writeFloat(-std.math.inf(f32));
            try w.endArray();
        }
    }.build;
    try expectWritten(.{}, "[null,null]", build);
    try expectWritten(.{ .non_finite = .literal }, "[NaN,-Infinity]", build);
    try testing.expectError(error.NonFiniteNumber, expectWritten(.{ .non_finite = .fail }, "", build));
}

test "keys and strings are escaped, and ASCII-only output escapes the rest" {
    const build = struct {
        fn build(w: *Writer) Error!void {
            try w.beginObject();
            try w.field("naïve \"key\"", "line\nbreak ✓");
            try w.endObject();
        }
    }.build;
    try expectWritten(.{}, "{\"naïve \\\"key\\\"\":\"line\\nbreak ✓\"}", build);
    try expectWritten(.{ .escape_unicode = true }, "{\"na\\u00efve \\\"key\\\"\":\"line\\nbreak \\u2713\"}", build);
}

test "numbers from a JSON5 reader come out as JSON" {
    const build = struct {
        fn build(w: *Writer) Error!void {
            try w.beginArray();
            for ([_][]const u8{ "1.50", "-0", "1e2", "0x1F", "+3", ".5", "5.", "-Infinity" }) |text| {
                try w.writeNumber(.{ .text = text });
            }
            try w.endArray();
        }
    }.build;
    try expectWritten(.{}, "[1.50,-0,1e2,31,3,0.5,5.0,null]", build);
}

test "integers of any width are written in full" {
    try expectWritten(.{}, "[340282366920938463463374607431768211455,-170141183460469231731687303715884105728]", struct {
        fn build(w: *Writer) Error!void {
            try w.beginArray();
            try w.writeInt(@as(u128, std.math.maxInt(u128)));
            try w.writeInt(@as(i128, std.math.minInt(i128)));
            try w.endArray();
        }
    }.build);
}

test "strings too long to hold back are written straight out" {
    var long: [400]u8 = undefined;
    @memset(&long, 'x');
    var buf: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var writer: Writer = .init(&out, .{ .indent = 2 });
    try writer.beginObject();
    try writer.field("short", 1);
    try writer.field(&long, @as([]const u8, &long));
    try writer.endObject();
    const text = out.buffered();
    try testing.expect(std.mem.startsWith(u8, text, "{\n  \"short\": 1,\n  \"xxx"));
    try testing.expect(std.mem.endsWith(u8, text, "xxx\"\n}"));
}

fn expectCbor(options: Options, comptime expected_hex: []const u8, comptime build: fn (*Writer) Error!void) !void {
    var buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var with_cbor = options;
    with_cbor.format = .cbor;
    var writer: Writer = .init(&out, with_cbor);
    try build(&writer);
    try testing.expectEqualSlices(u8, &cbor.hex(expected_hex), out.buffered());
}

test "CBOR is the same values in binary, after the tag that says it is CBOR" {
    const expected = "d9d9f7 bf 646e616d65 63416461 63706f73 bf 6178 f93e00 6179 f9c000 ff 6474616773 9fff" ++
        " 69696e76656e746f7279 9f bf 646974656d 6573776f7264 65636f756e74 01 ff f6 ff 65616c697665 f5 ff";
    try expectCbor(.{}, expected, sample);
    try expectCbor(.{ .indent = 2, .line_width = 20 }, expected, sample);
}

test "non-finite floats in CBOR follow the option, and are floats when literal" {
    const build = struct {
        fn build(w: *Writer) Error!void {
            try w.beginArray();
            try w.writeFloat(std.math.nan(f64));
            try w.writeFloat(-std.math.inf(f32));
            try w.endArray();
        }
    }.build;
    try expectCbor(.{}, "d9d9f7 9f f6 f6 ff", build);
    try expectCbor(.{ .non_finite = .literal }, "d9d9f7 9f f97e00 f9fc00 ff", build);
    try testing.expectError(error.NonFiniteNumber, expectCbor(.{ .non_finite = .fail }, "", build));
}

test "an integer past what CBOR holds is written as the float nearest it" {
    try expectCbor(.{}, "d9d9f7 9f 1bffffffffffffffff 3bffffffffffffffff fb47f0000000000000 faff000000 ff", struct {
        fn build(w: *Writer) Error!void {
            try w.beginArray();
            try w.writeInt(@as(u64, std.math.maxInt(u64)));
            try w.writeInt(@as(i128, -18446744073709551616));
            try w.writeInt(@as(u128, std.math.maxInt(u128)));
            try w.writeInt(@as(i128, std.math.minInt(i128)));
            try w.endArray();
        }
    }.build);
}

test "numbers from a reader keep their kind in CBOR" {
    try expectCbor(.{}, "d9d9f7 9f f93e00 00 181f f95640 1bffffffffffffffff fa5f800000 f6 ff", struct {
        fn build(w: *Writer) Error!void {
            try w.beginArray();
            for ([_][]const u8{ "1.50", "-0", "0x1F", "1e2", "18446744073709551615", "18446744073709551616", "-Infinity" }) |text| {
                try w.writeNumber(.{ .text = text });
            }
            try w.endArray();
        }
    }.build);
}
