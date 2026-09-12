// SPDX-License-Identifier: CC0-1.0

//! JSON one token at a time, from text, from CBOR, or from a `Value` already
//! in memory, with the same calls every way.
//!
//! ```zig
//! var reader: json.Reader = .init(gpa, text, .{});
//! defer reader.deinit();
//! while (try reader.next()) |token| switch (token) {
//!     .key => |name| std.debug.print("{s}: ", .{name}),
//!     .number => |n| total += n.asFloat(f64),
//!     else => {},
//! };
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Diagnostics = @import("Diagnostics.zig");
const number = @import("number.zig");
const Number = number.Number;
const utf8 = @import("utf8.zig");
const Value = @import("value.zig").Value;
const cbor = @import("cbor.zig");

const Reader = @This();

/// What the bytes are.
pub const Format = enum {
    /// JSON text, in the syntax `syntax` names.
    json,
    /// CBOR (RFC 8949): the same values in binary. Maps with text keys are
    /// objects, byte strings are base64url text as RFC 8949 converts them,
    /// and tags are passed over to what they tag.
    cbor,
};

pub const Syntax = enum {
    /// RFC 8259 and nothing more: what every other program accepts.
    json,
    /// Also `//` and `/* */` comments and trailing commas, as in VS Code's
    /// settings files.
    jsonc,
    /// All of JSON5: what jsonc allows, and unquoted keys, 'single quotes',
    /// hex, `.5` and `5.`, a leading `+`, `Infinity` and `NaN`, and strings
    /// continued across lines with a backslash.
    json5,
};

pub const Options = struct {
    syntax: Syntax = .json,
    /// JSON text or CBOR. Null tells them apart by the CBOR self-described
    /// tag, which the `Writer` puts at the start of all it writes as CBOR;
    /// CBOR from elsewhere, without one, has to be named.
    format: ?Format = null,
    /// Nesting deeper than this is refused with `error.TooDeep` instead of
    /// being followed. At most `max_depth_limit`.
    max_depth: u16 = 512,
    diagnostics: ?*Diagnostics = null,
};

pub const max_depth_limit = 1024;

/// What reading CBOR keeps for its open maps and arrays, at the deepest
/// nesting there can be: room enough for a fixed buffer to read with.
pub const CborFrames = [max_depth_limit]Cbor.Frame;

pub const Token = union(enum) {
    object_begin,
    object_end,
    array_begin,
    array_end,
    /// An object member's name, escapes decoded. Valid until the next call.
    key: []const u8,
    /// Escapes decoded. Valid until the next call.
    string: []const u8,
    number: Number,
    bool: bool,
    null,
};

pub const Kind = std.meta.Tag(Token);

pub const Error = error{ SyntaxError, TooDeep, OutOfMemory };

pub const Location = Diagnostics.Location;

gpa: Allocator,
diagnostics: ?*Diagnostics,
max_depth: u16,
/// How many objects and arrays are open.
depth: u16 = 0,
peeked: Peeked = .none,
tree: ?Tree = null,
/// Set when the input is CBOR.
binary: ?Cbor = null,

input: []const u8 = "",
pos: usize = 0,
syntax: Syntax = .json,
state: State = .start,
/// Where the last token read or peeked begins in `input`.
token_start: usize = 0,
objects: [max_depth_limit / 64]u64 = @splat(0),
scratch: std.ArrayListUnmanaged(u8) = .empty,

const State = enum { start, value, item, item_or_end, key, key_or_end, colon, comma_or_end, done };
const Scan = enum { decode, skip };
const Peeked = union(enum) { none, token: Token, end };

/// Read `input`. `gpa` holds strings whose escapes had to be decoded - and
/// for CBOR, what each open map and array has left in it - and nothing else.
pub fn init(gpa: Allocator, input: []const u8, options: Options) Reader {
    const bom = "\xEF\xBB\xBF";
    const is_cbor = options.format == .cbor or
        (options.format == null and std.mem.startsWith(u8, input, &cbor.self_described));
    if (is_cbor) return .{
        .gpa = gpa,
        .diagnostics = options.diagnostics,
        .max_depth = @min(options.max_depth, max_depth_limit),
        .input = input,
        .binary = .{},
    };
    return .{
        .gpa = gpa,
        .diagnostics = options.diagnostics,
        .max_depth = @min(options.max_depth, max_depth_limit),
        .input = input,
        .pos = if (std.mem.startsWith(u8, input, bom)) bom.len else 0,
        .syntax = options.syntax,
    };
}

/// Walk `value` as if it had been read from text. Only `max_depth` and
/// `diagnostics` of the options apply.
pub fn initValue(gpa: Allocator, value: Value, options: Options) Reader {
    return .{
        .gpa = gpa,
        .diagnostics = options.diagnostics,
        .max_depth = @min(options.max_depth, max_depth_limit),
        .tree = .{ .root = value },
    };
}

pub fn deinit(r: *Reader) void {
    r.scratch.deinit(r.gpa);
    if (r.tree) |*t| t.stack.deinit(r.gpa);
    if (r.binary) |*c| {
        c.stack.deinit(r.gpa);
        c.base64.deinit(r.gpa);
    }
    r.* = undefined;
}

/// The next token, or null after the last one. Text after the value that is
/// not white space is an error, not ignored.
pub fn next(r: *Reader) Error!?Token {
    return r.advance(.decode);
}

/// What the next token is, without taking it. In text this is told from its
/// first character, so a token that starts well and then goes wrong is
/// reported by the `next` that takes it.
pub fn peek(r: *Reader) Error!?Kind {
    switch (r.peeked) {
        .token => |token| return token,
        .end => return null,
        .none => {},
    }
    if (r.tree == null and r.binary == null) return r.peekText();
    if (try r.advance(.decode)) |token| {
        r.peeked = .{ .token = token };
        return token;
    }
    r.peeked = .end;
    return null;
}

/// Pass over the next value, however deep, without decoding its strings.
pub fn skipValue(r: *Reader) Error!void {
    const first = try r.advance(.skip) orelse return;
    switch (first) {
        .object_begin, .array_begin => {
            if (r.tree) |*t| {
                _ = t.stack.pop();
                r.depth -= 1;
                return;
            }
            const outside = r.depth - 1;
            while (r.depth > outside) _ = try r.advance(.skip) orelse return r.failEnd();
        },
        else => {},
    }
}

/// Line and column of the last token. Zero for a reader walking a `Value`,
/// and for CBOR, which has no lines: there `token_start` is the byte.
pub fn location(r: *const Reader) Location {
    if (r.tree != null or r.binary != null) return .{ .line = 0, .column = 0 };
    return Diagnostics.locate(r.input, r.token_start);
}

/// Describe a problem with the last token, for code that reads tokens and
/// finds the wrong one. Returns nothing: the caller picks the error.
pub fn report(r: *Reader, comptime fmt: []const u8, args: anytype) void {
    r.reportAt(r.token_start, fmt, args);
}

/// Describe a problem at `offset` in the text.
pub fn reportAt(r: *Reader, offset: usize, comptime fmt: []const u8, args: anytype) void {
    const d = r.diagnostics orelse return;
    r.place(d, offset);
    d.setMessage(fmt, args);
    d.path_len = 0;
}

/// Point `d` at `offset`: a line and a column in text, a byte in CBOR, and
/// nowhere in a tree.
fn place(r: *const Reader, d: *Diagnostics, offset: usize) void {
    if (r.binary != null) {
        d.setByte(offset);
    } else if (r.tree == null) {
        d.setPlace(r.input, offset);
    } else d.setNoPlace();
}

fn advance(r: *Reader, comptime scan: Scan) Error!?Token {
    switch (r.peeked) {
        .token => |token| {
            r.peeked = .none;
            return token;
        },
        .end => return null,
        .none => {},
    }
    if (r.binary != null) return r.cborNext(scan);
    if (r.tree != null) return r.treeNext();
    return r.textNext(scan);
}

// Good JSON takes the short paths below, which know the grammar and nothing
// else. Every mistake goes to an `explain` function that reads the text again
// to say what is wrong: formatting messages here would give every token a
// large stack frame.

fn textNext(r: *Reader, comptime scan: Scan) Error!?Token {
    try r.settle();
    switch (r.state) {
        .done => return if (r.pos >= r.input.len) null else r.explain(),
        .comma_or_end => return if (r.input[r.pos] == '}' or r.input[r.pos] == ']') try r.close() else r.explain(),
        .key, .key_or_end => return try r.textKey(scan),
        .start, .value, .item, .item_or_end => return try r.textValue(scan),
        .colon => unreachable,
    }
}

fn peekText(r: *Reader) Error!?Kind {
    try r.settle();
    if (r.state == .done) return if (r.pos >= r.input.len) null else r.explain();
    if (r.pos >= r.input.len) return r.explain();
    r.token_start = r.pos;
    const c = r.input[r.pos];
    return switch (r.state) {
        .comma_or_end => switch (c) {
            '}' => .object_end,
            ']' => .array_end,
            else => r.explain(),
        },
        .key, .key_or_end => if (c == '}') .object_end else .key,
        else => switch (c) {
            '{' => .object_begin,
            '[' => .array_begin,
            ']' => .array_end,
            '"', '\'' => .string,
            't', 'f' => .bool,
            'n' => .null,
            else => .number,
        },
    };
}

/// Pass over white space and the ':' or ',' that comes before the next token.
/// In `.comma_or_end` it stops at anything else, which is for the caller.
fn settle(r: *Reader) Error!void {
    try r.skipSpace();
    while (true) switch (r.state) {
        .colon => {
            if (r.pos >= r.input.len or r.input[r.pos] != ':') return r.explain();
            r.pos += 1;
            try r.skipSpace();
            r.state = .value;
        },
        .comma_or_end => {
            if (r.pos >= r.input.len) return r.explain();
            if (r.input[r.pos] != ',') return;
            r.pos += 1;
            try r.skipSpace();
            r.state = if (r.inObject()) .key else .item;
        },
        else => return,
    };
}

fn textKey(r: *Reader, comptime scan: Scan) Error!?Token {
    if (r.pos >= r.input.len) return r.explain();
    const c = r.input[r.pos];
    r.token_start = r.pos;
    const name = switch (c) {
        '"' => try r.string('"', scan),
        '}' => return if (r.state == .key_or_end or r.syntax != .json) try r.close() else r.explain(),
        else => if (r.syntax != .json5)
            return r.explain()
        else if (c == '\'')
            try r.string('\'', scan)
        else if (isWordStart(c) or c == '\\' or c >= 0x80)
            try r.identifier(scan)
        else
            return r.explain(),
    };
    r.state = .colon;
    return .{ .key = name };
}

fn textValue(r: *Reader, comptime scan: Scan) Error!?Token {
    if (r.pos >= r.input.len) return r.explain();
    const c = r.input[r.pos];
    r.token_start = r.pos;
    switch (c) {
        '{' => {
            try r.open(true);
            r.state = .key_or_end;
            return .object_begin;
        },
        '[' => {
            try r.open(false);
            r.state = .item_or_end;
            return .array_begin;
        },
        '"' => {
            const text = try r.string('"', scan);
            r.afterValue();
            return .{ .string = text };
        },
        '-', '0'...'9' => return .{ .number = try r.numberToken() },
        't' => return r.literal("true", .{ .bool = true }),
        'f' => return r.literal("false", .{ .bool = false }),
        'n' => return r.literal("null", .null),
        ']' => return if (r.state == .item_or_end or (r.state == .item and r.syntax != .json)) try r.close() else r.explain(),
        else => {
            if (r.syntax == .json5) switch (c) {
                '\'' => {
                    const text = try r.string('\'', scan);
                    r.afterValue();
                    return .{ .string = text };
                },
                '+', '.', 'I', 'N' => return .{ .number = try r.numberToken() },
                else => {},
            };
            return r.explain();
        },
    }
}

fn literal(r: *Reader, comptime name: []const u8, token: Token) Error!?Token {
    const in = r.input;
    const end = r.pos + name.len;
    if (end > in.len or !std.mem.eql(u8, in[r.pos..end], name) or (end < in.len and isWordPart(in[end])))
        return r.explain();
    r.pos = end;
    r.afterValue();
    return token;
}

fn open(r: *Reader, is_object: bool) Error!void {
    if (r.depth >= r.max_depth) return r.tooDeep();
    const bit = @as(u64, 1) << @intCast(r.depth % 64);
    if (is_object) r.objects[r.depth / 64] |= bit else r.objects[r.depth / 64] &= ~bit;
    r.depth += 1;
    r.pos += 1;
}

fn close(r: *Reader) Error!Token {
    const is_object = r.inObject();
    if (is_object != (r.input[r.pos] == '}')) return r.explainClose();
    r.token_start = r.pos;
    r.pos += 1;
    r.depth -= 1;
    r.afterValue();
    return if (is_object) .object_end else .array_end;
}

fn inObject(r: *const Reader) bool {
    if (r.depth == 0) return false;
    const level = r.depth - 1;
    return r.objects[level / 64] & (@as(u64, 1) << @intCast(level % 64)) != 0;
}

fn afterValue(r: *Reader) void {
    r.state = if (r.depth == 0) .done else .comma_or_end;
}

fn numberToken(r: *Reader) Error!Number {
    const start = r.pos;
    const end = (if (r.syntax == .json5) scanNumber5(r.input, start) else scanNumber(r.input, start)) orelse
        return r.explain();
    r.pos = end;
    r.afterValue();
    return .{ .text = r.input[start..end] };
}

/// Where the JSON number at `start` ends, or null if there is none there.
fn scanNumber(in: []const u8, start: usize) ?usize {
    var i = start;
    if (i < in.len and in[i] == '-') i += 1;
    if (i >= in.len) return null;
    if (in[i] == '0') {
        i += 1;
    } else if (in[i] >= '1' and in[i] <= '9') {
        i = digitsEnd(in, i + 1);
    } else return null;
    if (i < in.len and in[i] == '.') {
        const fraction = i + 1;
        i = digitsEnd(in, fraction);
        if (i == fraction) return null;
    }
    return exponentEnd(in, i);
}

/// The same for a JSON5 number, which may also be hex, `Infinity` or `NaN`,
/// have a leading `+`, and start or end with its decimal point.
fn scanNumber5(in: []const u8, start: usize) ?usize {
    var i = start;
    if (i < in.len and (in[i] == '-' or in[i] == '+')) i += 1;
    const rest = in[i..];
    if (std.mem.startsWith(u8, rest, "Infinity") or std.mem.startsWith(u8, rest, "NaN")) {
        i += if (rest[0] == 'I') "Infinity".len else "NaN".len;
    } else if (rest.len > 2 and rest[0] == '0' and (rest[1] | 0x20) == 'x' and std.ascii.isHex(rest[2])) {
        i += 2;
        while (i < in.len and std.ascii.isHex(in[i])) i += 1;
    } else {
        const whole = i;
        i = if (i < in.len and in[i] == '0') i + 1 else digitsEnd(in, i);
        var fraction = false;
        if (i < in.len and in[i] == '.') {
            const after = i + 1;
            i = digitsEnd(in, after);
            fraction = i > after;
        }
        if (i == whole or (i == whole + 1 and in[whole] == '.' and !fraction)) return null;
        return exponentEnd(in, i);
    }
    if (i < in.len and (isWordPart(in[i]) or in[i] == '.')) return null;
    return i;
}

fn digitsEnd(in: []const u8, start: usize) usize {
    var i = start;
    while (i < in.len and std.ascii.isDigit(in[i])) i += 1;
    return i;
}

fn exponentEnd(in: []const u8, start: usize) ?usize {
    var i = start;
    if (i < in.len and (in[i] | 0x20) == 'e') {
        i += 1;
        if (i < in.len and (in[i] == '+' or in[i] == '-')) i += 1;
        const digits = i;
        i = digitsEnd(in, i);
        if (i == digits) return null;
    }
    if (i < in.len and (isWordPart(in[i]) or in[i] == '.')) return null;
    return i;
}

fn wordAt(r: *const Reader, start: usize) []const u8 {
    var end = start;
    while (end < r.input.len and isWordPart(r.input[end])) end += 1;
    return r.input[start..end];
}

fn numberAt(r: *const Reader, start: usize) []const u8 {
    var end = start + 1;
    while (end < r.input.len and (isWordPart(r.input[end]) or r.input[end] == '.' or r.input[end] == '+' or r.input[end] == '-')) end += 1;
    return r.input[start..end];
}

/// What is wrong at `r.pos`, where the text cannot go on as it does.
fn explain(r: *Reader) error{SyntaxError} {
    @branchHint(.cold);
    const at = r.pos;
    if (at >= r.input.len) return r.failEnd();
    const c = r.input[at];
    switch (r.state) {
        .done => return r.fail(at, "unexpected {f} after the end of the JSON value", .{r.found(at)}),
        .colon => return r.fail(at, "expected ':' after the key, found {f}", .{r.found(at)}),
        .comma_or_end => if (r.inObject())
            return r.fail(at, "expected ',' or '}}' after an object member, found {f}", .{r.found(at)})
        else
            return r.fail(at, "expected ',' or ']' after an array item, found {f}", .{r.found(at)}),
        .key, .key_or_end => {
            if (c == '}') return r.fail(at, "JSON does not allow a comma before '}}' (.jsonc and .json5 do)", .{});
            if (c == '\'') return r.fail(at, "keys need double quotes in JSON, \"like this\" (single quotes are JSON5)", .{});
            if (isWordStart(c)) return r.fail(at, "keys need double quotes in JSON: \"{s}\" (unquoted keys are JSON5)", .{r.wordAt(at)});
            if (r.state == .key_or_end) return r.fail(at, "expected a key in double quotes or '}}', found {f}", .{r.found(at)});
            return r.fail(at, "expected a key in double quotes, found {f}", .{r.found(at)});
        },
        .start, .value, .item, .item_or_end => switch (c) {
            '-', '+', '.', '0'...'9' => return r.explainNumber(at),
            '\'' => return r.fail(at, "text needs double quotes in JSON, \"like this\" (single quotes are JSON5)", .{}),
            ']' => if (r.state == .item)
                return r.fail(at, "JSON does not allow a comma before ']' (.jsonc and .json5 do)", .{})
            else
                return r.fail(at, "expected a value, found ']'", .{}),
            else => {
                if (isWordStart(c)) return r.explainWord(at);
                if (r.state == .value) return r.fail(at, "expected a value after ':', found {f}", .{r.found(at)});
                return r.fail(at, "expected a value, found {f}", .{r.found(at)});
            },
        },
    }
}

fn explainNumber(r: *Reader, start: usize) error{SyntaxError} {
    @branchHint(.cold);
    const in = r.input;
    const json5 = r.syntax == .json5;
    if (!json5 and in[start] == '+') return r.fail(start, "JSON numbers cannot start with '+' (JSON5 ones can)", .{});
    if (!json5 and in[start] == '.') return r.fail(start, "a JSON number needs a digit before the '.': write 0.5, not .5", .{});
    var i = start + @intFromBool(in[start] == '-' or in[start] == '+');
    const word = r.wordAt(i);
    if (!json5 and (std.mem.eql(u8, word, "Infinity") or std.mem.eql(u8, word, "NaN")))
        return r.fail(start, "{s} is not a JSON number (JSON5 allows it)", .{word});
    if (json5 and word.len >= 2 and word[0] == '0' and (word[1] | 0x20) == 'x' and (word.len == 2 or !std.ascii.isHex(word[2])))
        return r.fail(start, "expected hex digits after '0x'", .{});
    if (i + 1 < in.len and in[i] == '0' and std.ascii.isDigit(in[i + 1])) {
        const negative = in[start] == '-';
        var digits = r.numberAt(start)[@intFromBool(negative)..];
        while (digits.len > 1 and digits[0] == '0' and std.ascii.isDigit(digits[1])) digits = digits[1..];
        return r.fail(start, "JSON numbers cannot have leading zeros: write {s}{s}", .{ if (negative) "-" else "", digits });
    }
    const whole = digitsEnd(in, i) - i;
    i += whole;
    if (whole == 0 and !(json5 and i < in.len and in[i] == '.'))
        return r.fail(start, "expected a digit after '{c}'", .{in[start]});
    if (i < in.len and in[i] == '.') {
        const fraction = digitsEnd(in, i + 1) - (i + 1);
        i += 1 + fraction;
        if (fraction == 0 and !(json5 and whole > 0)) return r.fail(i, "expected a digit after the decimal point", .{});
    }
    if (i < in.len and (in[i] | 0x20) == 'e') {
        i += 1;
        if (i < in.len and (in[i] == '+' or in[i] == '-')) i += 1;
        if (digitsEnd(in, i) == i) return r.fail(i, "expected a digit in the exponent", .{});
    }
    return r.fail(start, "'{s}' is not a number", .{r.numberAt(start)});
}

fn explainWord(r: *Reader, start: usize) error{SyntaxError} {
    @branchHint(.cold);
    const text = r.wordAt(start);
    if (std.mem.eql(u8, text, "Infinity") or std.mem.eql(u8, text, "NaN"))
        return r.fail(start, "{s} is not a JSON number (JSON5 allows it)", .{text});
    for ([_][]const u8{ "true", "false", "null" }) |name| if (std.ascii.eqlIgnoreCase(text, name))
        return r.fail(start, "JSON is case-sensitive: write {s}, not {s}", .{ name, text });
    for ([_][]const u8{ "None", "nil", "undefined" }) |absent| if (std.mem.eql(u8, text, absent))
        return r.fail(start, "JSON has no {s}: an empty value is written null", .{text});
    return r.fail(start, "unexpected word '{s}': text needs double quotes, \"{s}\"", .{ text, text });
}

fn explainClose(r: *Reader) error{SyntaxError} {
    @branchHint(.cold);
    if (r.inObject()) return r.fail(r.pos, "expected '}}' to close the object, found ']'", .{});
    return r.fail(r.pos, "expected ']' to close the array, found '}}'", .{});
}

fn string(r: *Reader, quote: u8, comptime scan: Scan) Error![]const u8 {
    const in = r.input;
    const opening = r.pos;
    const start = opening + 1;
    var i = start;
    while (true) {
        i = utf8.plainRun(in, i, quote);
        if (i >= in.len) return r.unclosedString(opening);
        const c = in[i];
        if (c == quote) {
            r.pos = i + 1;
            return in[start..i];
        }
        if (c == '\\') break;
        if (c < 0x20) return r.controlInString(i);
        i += try r.utf8Length(i);
    }

    if (scan == .decode) r.scratch.clearRetainingCapacity();
    var run = start;
    while (true) {
        i = utf8.plainRun(in, i, quote);
        if (i >= in.len) return r.unclosedString(opening);
        const c = in[i];
        if (c == quote or c == '\\') {
            if (scan == .decode) try r.scratch.appendSlice(r.gpa, in[run..i]);
            if (c == quote) {
                r.pos = i + 1;
                return if (scan == .decode) r.scratch.items else "";
            }
            i = try r.escape(i, scan);
            run = i;
            continue;
        }
        if (c < 0x20) return r.controlInString(i);
        i += try r.utf8Length(i);
    }
}

fn unclosedString(r: *Reader, opening: usize) error{SyntaxError} {
    @branchHint(.cold);
    return r.fail(opening, "this string is never closed: its closing {c} is missing", .{r.input[opening]});
}

fn controlInString(r: *Reader, at: usize) error{SyntaxError} {
    @branchHint(.cold);
    return switch (r.input[at]) {
        '\n', '\r' => r.fail(at, "a string cannot hold a line break as it is: write \\n", .{}),
        '\t' => r.fail(at, "a string cannot hold a tab as it is: write \\t", .{}),
        else => |c| r.fail(at, "a string cannot hold control character U+{X:0>4} as it is: write \\u{x:0>4}", .{ c, c }),
    };
}

/// Decode the escape at `at`, which is a backslash, and return where the
/// string continues.
fn escape(r: *Reader, at: usize, comptime scan: Scan) Error!usize {
    const in = r.input;
    if (at + 1 >= in.len) return r.unclosedString(at);
    var buf: [4]u8 = undefined;
    var after = at + 2;
    const bytes: []const u8 = switch (in[at + 1]) {
        '"' => "\"",
        '\\' => "\\",
        '/' => "/",
        'b' => "\x08",
        'f' => "\x0c",
        'n' => "\n",
        'r' => "\r",
        't' => "\t",
        'u' => blk: {
            var cp = try r.hex(at, after, 4);
            after += 4;
            if (cp >= 0xD800 and cp <= 0xDBFF) {
                const low = if (after + 6 <= in.len and in[after] == '\\' and in[after + 1] == 'u')
                    try r.hex(after, after + 2, 4)
                else
                    0;
                if (low >= 0xDC00 and low <= 0xDFFF) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                    after += 6;
                } else cp = 0xFFFD;
            } else if (cp >= 0xDC00 and cp <= 0xDFFF) cp = 0xFFFD;
            break :blk buf[0 .. std.unicode.utf8Encode(cp, &buf) catch unreachable];
        },
        else => |c| blk: {
            if (r.syntax != .json5) {
                if (c == '\'') return r.fail(at, "JSON strings do not escape ': write it as it is", .{});
                if (c >= 0x20 and c < 0x7F) return r.fail(at, "'\\{c}' is not a JSON escape", .{c});
                return r.fail(at, "a backslash cannot be followed by {f}", .{r.found(at + 1)});
            }
            switch (c) {
                '\'' => break :blk "'",
                'v' => break :blk "\x0b",
                '0' => {
                    if (after < in.len and std.ascii.isDigit(in[after])) return r.fail(at, "'\\0' cannot be followed by a digit", .{});
                    break :blk "\x00";
                },
                '1'...'9' => return r.fail(at, "'\\{c}' is not an escape", .{c}),
                'x' => {
                    const cp = try r.hex(at, after, 2);
                    after += 2;
                    break :blk buf[0 .. std.unicode.utf8Encode(cp, &buf) catch unreachable];
                },
                '\n' => break :blk "",
                '\r' => {
                    if (after < in.len and in[after] == '\n') after += 1;
                    break :blk "";
                },
                else => {
                    if (c < 0x80) break :blk in[at + 1 ..][0..1];
                    const len = try r.utf8Length(at + 1);
                    after = at + 1 + len;
                    const line_separators = [_][]const u8{ "\u{2028}", "\u{2029}" };
                    for (line_separators) |separator| if (std.mem.eql(u8, in[at + 1 .. after], separator)) break :blk "";
                    break :blk in[at + 1 .. after];
                },
            }
        },
    };
    if (scan == .decode) try r.scratch.appendSlice(r.gpa, bytes);
    return after;
}

fn hex(r: *Reader, escape_at: usize, at: usize, comptime digits: usize) Error!u21 {
    if (at + digits > r.input.len) return r.fail(escape_at, "expected {d} hex digits in this escape", .{digits});
    var cp: u21 = 0;
    for (r.input[at..][0..digits]) |c| {
        const digit = std.fmt.charToDigit(c, 16) catch
            return r.fail(escape_at, "expected {d} hex digits in this escape", .{digits});
        cp = cp * 16 + digit;
    }
    return cp;
}

/// The length of the valid UTF-8 character that starts at `at`.
fn utf8Length(r: *Reader, at: usize) Error!usize {
    return utf8.sequenceLength(r.input[at..]) orelse r.explainUtf8(at);
}

fn explainUtf8(r: *Reader, at: usize) error{SyntaxError} {
    @branchHint(.cold);
    const first = r.input[at];
    if (first >= 0xC2 and first <= 0xF4)
        return r.fail(at, "this is not UTF-8 text: byte 0x{X:0>2} starts a broken character", .{first});
    return r.fail(at, "this is not UTF-8 text: byte 0x{X:0>2} cannot be here", .{first});
}

/// A JSON5 key written without quotes.
fn identifier(r: *Reader, comptime scan: Scan) Error![]const u8 {
    const in = r.input;
    const start = r.pos;
    var i = start;
    var escaped = false;
    if (scan == .decode) r.scratch.clearRetainingCapacity();
    while (i < in.len) {
        const c = in[i];
        if (c == '\\') {
            if (i + 1 >= in.len or in[i + 1] != 'u') return r.fail(i, "only \\u escapes can be used in a key without quotes", .{});
            const cp = try r.hex(i, i + 2, 4);
            if (!escaped and scan == .decode) try r.scratch.appendSlice(r.gpa, in[start..i]);
            escaped = true;
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch
                return r.fail(i, "\\u{x:0>4} cannot be in a key", .{cp});
            if (scan == .decode) try r.scratch.appendSlice(r.gpa, buf[0..len]);
            i += 6;
            continue;
        }
        const len: usize = if (c < 0x80) 1 else try r.utf8Length(i);
        if (c < 0x80 and !isWordPart(c)) break;
        if (c >= 0x80 and json5SpaceLength(in[i..]) != null) break;
        if (escaped and scan == .decode) try r.scratch.appendSlice(r.gpa, in[i..][0..len]);
        i += len;
    }
    if (i == start) return r.fail(start, "expected a key, found {f}", .{r.found(start)});
    r.pos = i;
    if (!escaped) return in[start..i];
    return if (scan == .decode) r.scratch.items else "";
}

inline fn skipSpace(r: *Reader) Error!void {
    if (r.pos < r.input.len) {
        const c = r.input[r.pos];
        if (c > ' ' and c != '/' and c < 0x80) return;
    }
    return r.skipSpaceAndComments();
}

fn skipSpaceAndComments(r: *Reader) Error!void {
    const in = r.input;
    var i = r.pos;
    while (i < in.len) switch (in[i]) {
        ' ', '\t', '\n', '\r' => i += 1,
        '/' => {
            if (r.syntax == .json) return r.fail(i, "JSON does not allow comments (.jsonc and .json5 do)", .{});
            i = try r.comment(i);
        },
        0x0B, 0x0C => if (r.syntax == .json5) {
            i += 1;
        } else break,
        0xC2, 0xE1, 0xE2, 0xE3, 0xEF => if (r.syntax == .json5) {
            i += json5SpaceLength(in[i..]) orelse break;
        } else break,
        else => break,
    };
    r.pos = i;
}

fn comment(r: *Reader, at: usize) Error!usize {
    const in = r.input;
    if (at + 1 < in.len and in[at + 1] == '/') {
        return std.mem.indexOfScalarPos(u8, in, at + 2, '\n') orelse in.len;
    }
    if (at + 1 < in.len and in[at + 1] == '*') {
        const end = std.mem.indexOfPos(u8, in, at + 2, "*/") orelse
            return r.fail(at, "this comment is never closed: its */ is missing", .{});
        return end + 2;
    }
    return r.fail(at, "a comment starts with // or /*", .{});
}

fn json5SpaceLength(bytes: []const u8) ?usize {
    if (bytes.len >= 2 and bytes[0] == 0xC2 and bytes[1] == 0xA0) return 2;
    if (bytes.len < 3 or bytes[0] & 0xF0 != 0xE0 or bytes[1] & 0xC0 != 0x80 or bytes[2] & 0xC0 != 0x80) return null;
    const cp = (@as(u21, bytes[0] & 0x0F) << 12) | (@as(u21, bytes[1] & 0x3F) << 6) | (bytes[2] & 0x3F);
    return switch (cp) {
        0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => 3,
        else => null,
    };
}

fn isWordStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn isWordPart(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

noinline fn fail(r: *Reader, at: usize, comptime fmt: []const u8, args: anytype) error{SyntaxError} {
    @branchHint(.cold);
    if (r.diagnostics) |d| {
        r.place(d, at);
        d.setMessage(fmt, args);
        d.path_len = 0;
    }
    return error.SyntaxError;
}

fn tooDeep(r: *Reader) error{TooDeep} {
    if (r.diagnostics) |d| {
        r.place(d, if (r.binary != null) r.token_start else r.pos);
        d.setMessage("nested deeper than {d} levels", .{r.max_depth});
        d.path_len = 0;
    }
    return error.TooDeep;
}

fn failEnd(r: *Reader) error{SyntaxError} {
    const end = r.input.len;
    switch (r.state) {
        .start => return r.fail(end, "there is no JSON value here: the text is empty", .{}),
        .value => return r.fail(end, "the text ends where a value should follow ':'", .{}),
        .colon => return r.fail(end, "the text ends after a key, where ':' and a value should follow", .{}),
        else => {
            const opening = Diagnostics.locate(r.input, r.innermostOpening());
            return r.fail(end, "the text ends before the {s} opened at line {d}, column {d} is closed", .{
                if (r.inObject()) "object" else "array", opening.line, opening.column,
            });
        },
    }
}

/// Where the innermost object or array still open at the end of the text
/// begins. Only asked after the text has read cleanly up to its end, so
/// strings and comments are known to be well formed.
fn innermostOpening(r: *const Reader) usize {
    var openings: [max_depth_limit]usize = undefined;
    var depth: usize = 0;
    const in = r.input;
    var i: usize = 0;
    while (i < in.len) : (i += 1) switch (in[i]) {
        '{', '[' => {
            if (depth < openings.len) openings[depth] = i;
            depth += 1;
        },
        '}', ']' => depth -|= 1,
        '"', '\'' => |quote| {
            i += 1;
            while (i < in.len and in[i] != quote) : (i += 1) {
                if (in[i] == '\\') i += 1;
            }
        },
        '/' => if (i + 1 < in.len and in[i + 1] == '/') {
            i = std.mem.indexOfScalarPos(u8, in, i, '\n') orelse in.len;
        } else if (i + 1 < in.len and in[i + 1] == '*') {
            i = (std.mem.indexOfPos(u8, in, i + 2, "*/") orelse in.len) + 1;
        },
        else => {},
    };
    return if (depth > 0) openings[@min(depth, openings.len) - 1] else 0;
}

const Found = struct {
    input: []const u8,
    at: usize,

    pub fn format(f: Found, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (f.at >= f.input.len) return w.writeAll("the end of the text");
        const c = f.input[f.at];
        switch (c) {
            '\n', '\r' => try w.writeAll("a line break"),
            '\t' => try w.writeAll("a tab"),
            0...8, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => try w.print("control character U+{X:0>4}", .{c}),
            0x20...0x7E => try w.print("'{c}'", .{c}),
            else => {
                const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                const end = @min(f.input.len, f.at + len);
                if (std.unicode.utf8ValidateSlice(f.input[f.at..end]))
                    try w.print("'{s}'", .{f.input[f.at..end]})
                else
                    try w.print("byte 0x{X:0>2}", .{c});
            },
        }
    }
};

fn found(r: *const Reader, at: usize) Found {
    return .{ .input = r.input, .at = at };
}

const Tree = struct {
    root: Value,
    started: bool = false,
    stack: std.ArrayListUnmanaged(Frame) = .empty,
    number_buf: [number.max_float_len]u8 = undefined,

    const Frame = struct {
        container: Value,
        index: usize = 0,
        key_given: bool = false,
    };
};

fn treeNext(r: *Reader) Error!?Token {
    const t = &r.tree.?;
    if (!t.started) {
        t.started = true;
        return try r.treeEmit(t.root);
    }
    if (t.stack.items.len == 0) return null;
    const top = &t.stack.items[t.stack.items.len - 1];
    switch (top.container) {
        .array => |array| {
            if (top.index < array.list.items.len) {
                top.index += 1;
                return try r.treeEmit(array.list.items[top.index - 1]);
            }
            _ = t.stack.pop();
            r.depth -= 1;
            return .array_end;
        },
        .object => |object| {
            if (top.index < object.map.count()) {
                if (!top.key_given) {
                    top.key_given = true;
                    return .{ .key = object.map.keys()[top.index] };
                }
                top.key_given = false;
                top.index += 1;
                return try r.treeEmit(object.map.values()[top.index - 1]);
            }
            _ = t.stack.pop();
            r.depth -= 1;
            return .object_end;
        },
        else => unreachable,
    }
}

fn treeEmit(r: *Reader, value: Value) Error!Token {
    const t = &r.tree.?;
    switch (value) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .int => |i| return .{ .number = .{ .text = std.fmt.bufPrint(&t.number_buf, "{d}", .{i}) catch unreachable } },
        .float => |f| return .{ .number = .{ .text = floatText(&t.number_buf, f) } },
        .string => |s| return .{ .string = s },
        .array, .object => {
            if (r.depth >= r.max_depth) return r.tooDeep();
            try t.stack.append(r.gpa, .{ .container = value });
            r.depth += 1;
            return if (value == .array) .array_begin else .object_begin;
        },
    }
}

fn floatText(buf: *[number.max_float_len]u8, f: f64) []const u8 {
    if (std.math.isNan(f)) return "NaN";
    if (std.math.isInf(f)) return if (f > 0) "Infinity" else "-Infinity";
    return number.formatFloat(buf, f);
}

// -------------------------------------------------------------------------
// CBOR
// -------------------------------------------------------------------------
//
// Items become the tokens the same text would. Numbers are written out as
// text, as a tree's are: an integer exactly, and a float in the fewest digits
// that read back as the value it holds, whatever width it was written in.

const Cbor = struct {
    stack: std.ArrayListUnmanaged(Frame) = .empty,
    /// Where a byte string's base64 goes: its bytes may be in `scratch`.
    base64: std.ArrayListUnmanaged(u8) = .empty,
    number_buf: [number.max_float_len]u8 = undefined,
    done: bool = false,

    /// A map or an array still open.
    const Frame = struct {
        /// What is left of one of known length: items, or for a map, pairs.
        remaining: u64,
        opened_at: usize,
        is_object: bool,
        indefinite: bool,
        want_key: bool,
    };
};

fn cborNext(r: *Reader, comptime scan: Scan) Error!?Token {
    const c = &r.binary.?;
    if (c.done) {
        if (r.pos < r.input.len) return r.fail(r.pos, "unexpected byte 0x{X:0>2} after the end of the CBOR value", .{r.input[r.pos]});
        return null;
    }
    if (c.stack.items.len > 0) {
        const top = &c.stack.items[c.stack.items.len - 1];
        if (top.indefinite) {
            if (r.pos < r.input.len and r.input[r.pos] == cbor.break_byte) {
                if (top.is_object and !top.want_key) return r.fail(r.pos, "this map ends between a key and its value", .{});
                r.token_start = r.pos;
                r.pos += 1;
                return r.cborClose();
            }
        } else if (top.remaining == 0) {
            r.token_start = r.pos;
            return r.cborClose();
        }
        if (top.is_object and top.want_key) return try r.cborKey(scan);
    }
    return try r.cborValue(scan);
}

fn cborClose(r: *Reader) Token {
    const frame = r.binary.?.stack.pop().?;
    r.depth -= 1;
    r.cborDone();
    return if (frame.is_object) .object_end else .array_end;
}

/// A value is complete: the map or the array it is in moves on, or the
/// document is over.
fn cborDone(r: *Reader) void {
    const c = &r.binary.?;
    if (c.stack.items.len == 0) {
        c.done = true;
        return;
    }
    const top = &c.stack.items[c.stack.items.len - 1];
    if (top.is_object) top.want_key = true;
    if (!top.indefinite) top.remaining -= 1;
}

fn cborKey(r: *Reader, comptime scan: Scan) Error!Token {
    const head = try r.cborHead();
    if (head.major != .text) return r.fail(r.token_start, "a key must be text for JSON, and this map has {s} as one", .{cborKind(head)});
    const name = try r.cborBytes(head, .text, scan);
    const c = &r.binary.?;
    c.stack.items[c.stack.items.len - 1].want_key = false;
    return .{ .key = name };
}

fn cborValue(r: *Reader, comptime scan: Scan) Error!Token {
    const head = try r.cborHead();
    const c = &r.binary.?;
    switch (head.major) {
        .unsigned, .negative => {
            if (head.info == cbor.indefinite) return r.fail(r.token_start, "a number cannot be of indefinite length", .{});
            const text = if (scan == .skip)
                "0"
            else if (head.major == .unsigned)
                number.formatInt(&c.number_buf, head.argument)
            else
                number.formatInt(&c.number_buf, -1 - @as(i128, head.argument));
            r.cborDone();
            return .{ .number = .{ .text = text } };
        },
        .bytes => {
            const bytes = try r.cborBytes(head, .bytes, scan);
            const text = if (scan == .skip) "" else try r.base64(bytes);
            r.cborDone();
            return .{ .string = text };
        },
        .text => {
            const text = try r.cborBytes(head, .text, scan);
            r.cborDone();
            return .{ .string = text };
        },
        .array, .map => {
            const is_object = head.major == .map;
            if (r.depth >= r.max_depth) return r.tooDeep();
            // All at once, so the stack never grows piece by piece.
            if (c.stack.capacity == 0) try c.stack.ensureTotalCapacityPrecise(r.gpa, r.max_depth);
            c.stack.appendAssumeCapacity(.{
                .remaining = head.argument,
                .opened_at = r.token_start,
                .is_object = is_object,
                .indefinite = head.info == cbor.indefinite,
                .want_key = is_object,
            });
            r.depth += 1;
            return if (is_object) .object_begin else .array_begin;
        },
        .simple => {
            const token: Token = switch (head.info) {
                20 => .{ .bool = false },
                21 => .{ .bool = true },
                22, 23 => .null,
                25, 26, 27 => .{ .number = .{ .text = floatText(&c.number_buf, cbor.floatValue(head)) } },
                cbor.indefinite => {
                    if (c.stack.items.len == 0) return r.fail(r.token_start, "a break (0xFF) with nothing open for it to close", .{});
                    const container = if (c.stack.items[c.stack.items.len - 1].is_object) "a map" else "an array";
                    return r.fail(r.token_start, "a break (0xFF) in {s} of known length, which ends without one", .{container});
                },
                else => return r.fail(r.token_start, "simple value {d} has no JSON form", .{head.argument}),
            };
            r.cborDone();
            return token;
        },
        .tag => unreachable,
    }
}

/// The next item's head, past any tags on it: JSON has no tags, so what they
/// tag is read as it is.
fn cborHead(r: *Reader) Error!cbor.Head {
    while (true) {
        r.token_start = r.pos;
        const head = try r.cborReadHead();
        if (head.major != .tag) return head;
        if (head.info == cbor.indefinite) return r.fail(r.token_start, "a tag cannot be of indefinite length", .{});
        if (head.argument == 2 or head.argument == 3)
            return r.fail(r.token_start, "a big number (tag {d}) has no JSON form here", .{head.argument});
    }
}

fn cborReadHead(r: *Reader) Error!cbor.Head {
    const head = cbor.readHead(r.input[r.pos..]) catch |err| switch (err) {
        error.Truncated => return r.cborEnds(),
        error.Reserved => return r.fail(r.pos, "byte 0x{X:0>2} starts no CBOR item: additional information {d} is reserved", .{ r.input[r.pos], r.input[r.pos] & 0x1F }),
    };
    r.pos += head.size;
    return head;
}

/// A byte or text string's bytes. One of unknown length is its parts joined,
/// in `scratch`; each part of text has to be UTF-8 on its own.
fn cborBytes(r: *Reader, head: cbor.Head, comptime major: cbor.Major, comptime scan: Scan) Error![]const u8 {
    if (head.info != cbor.indefinite) return r.cborChunk(head.argument, major);
    if (scan == .decode) r.scratch.clearRetainingCapacity();
    while (true) {
        if (r.pos >= r.input.len) return r.cborEnds();
        if (r.input[r.pos] == cbor.break_byte) {
            r.pos += 1;
            return if (scan == .decode) r.scratch.items else "";
        }
        const part_at = r.pos;
        const part = try r.cborReadHead();
        if (part.major != major or part.info == cbor.indefinite)
            return r.fail(part_at, "a {s} of unknown length is made of {s}s of known length, and this part is not", .{ cborName(major), cborName(major) });
        const bytes = try r.cborChunk(part.argument, major);
        if (scan == .decode) try r.scratch.appendSlice(r.gpa, bytes);
    }
}

fn cborChunk(r: *Reader, length: u64, comptime major: cbor.Major) Error![]const u8 {
    if (length > r.input.len - r.pos) return r.cborEnds();
    const start = r.pos;
    const bytes = r.input[start..][0..@intCast(length)];
    r.pos += bytes.len;
    if (major == .text) {
        var i: usize = 0;
        while (true) {
            i = utf8.asciiRun(bytes, i);
            if (i >= bytes.len) break;
            i += utf8.sequenceLength(bytes[i..]) orelse return r.explainUtf8(start + i);
        }
    }
    return bytes;
}

/// A byte string as JSON can hold it: base64url text, as RFC 8949 converts it.
fn base64(r: *Reader, bytes: []const u8) Error![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out = &r.binary.?.base64;
    try out.resize(r.gpa, encoder.calcSize(bytes.len));
    return encoder.encode(out.items, bytes);
}

fn cborEnds(r: *Reader) error{SyntaxError} {
    @branchHint(.cold);
    const c = &r.binary.?;
    if (c.stack.items.len == 0) return r.fail(r.input.len, "the CBOR ends before its value is complete", .{});
    const top = c.stack.items[c.stack.items.len - 1];
    return r.fail(r.input.len, "the CBOR ends before the {s} opened at byte {d} is closed", .{ if (top.is_object) "map" else "array", top.opened_at });
}

fn cborName(major: cbor.Major) []const u8 {
    return if (major == .text) "text string" else "byte string";
}

fn cborKind(head: cbor.Head) []const u8 {
    return switch (head.major) {
        .unsigned, .negative => "a number",
        .bytes => "a byte string",
        .text => "text",
        .array => "an array",
        .map => "a map",
        .tag => "a tag",
        .simple => switch (head.info) {
            20, 21 => "a boolean",
            22, 23 => "null",
            25, 26, 27 => "a number",
            cbor.indefinite => "a break (0xFF)",
            else => "a simple value",
        },
    };
}

fn expectTokens(syntax: Syntax, text: []const u8, expected: []const Token) !void {
    return expectRead(.{ .syntax = syntax }, text, expected);
}

fn expectRead(options: Options, input: []const u8, expected: []const Token) !void {
    var reader: Reader = .init(testing.allocator, input, options);
    defer reader.deinit();
    for (expected) |want| {
        const got = (try reader.next()) orelse return error.TestUnexpectedEnd;
        try testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(got));
        switch (want) {
            .key => |s| try testing.expectEqualStrings(s, got.key),
            .string => |s| try testing.expectEqualStrings(s, got.string),
            .number => |n| try testing.expectEqualStrings(n.text, got.number.text),
            .bool => |b| try testing.expectEqual(b, got.bool),
            else => {},
        }
    }
    try testing.expectEqual(@as(?Token, null), try reader.next());
}

fn expectFailure(syntax: Syntax, text: []const u8, expected_error: Error, message: []const u8) !void {
    const diagnostics = try readToError(.{ .syntax = syntax }, text, expected_error);
    try testing.expectEqualStrings(message, diagnostics.message());
}

fn expectCborFailure(input: []const u8, message: []const u8, at: usize) !void {
    const diagnostics = try readToError(.{ .format = .cbor }, input, error.SyntaxError);
    try testing.expectEqualStrings(message, diagnostics.message());
    try testing.expect(diagnostics.binary);
    try testing.expectEqual(at, diagnostics.offset);
}

/// Read `input` until it fails, which it must, with `expected_error`: what
/// the diagnostics then say.
fn readToError(options: Options, input: []const u8, expected_error: Error) !Diagnostics {
    var diagnostics: Diagnostics = .{};
    var with_diagnostics = options;
    with_diagnostics.diagnostics = &diagnostics;
    var reader: Reader = .init(testing.allocator, input, with_diagnostics);
    defer reader.deinit();
    while (true) {
        const token = reader.next() catch |err| {
            try testing.expectEqual(expected_error, err);
            return diagnostics;
        };
        if (token == null) return error.TestExpectedError;
    }
}

test "tokens of a document" {
    try expectTokens(.json,
        \\{"name": "Ada", "level": 3, "tags": ["a", true, null], "pos": {"x": -1.5e3}}
    , &.{
        .object_begin,
        .{ .key = "name" },
        .{ .string = "Ada" },
        .{ .key = "level" },
        .{ .number = .{ .text = "3" } },
        .{ .key = "tags" },
        .array_begin,
        .{ .string = "a" },
        .{ .bool = true },
        .null,
        .array_end,
        .{ .key = "pos" },
        .object_begin,
        .{ .key = "x" },
        .{ .number = .{ .text = "-1.5e3" } },
        .object_end,
        .object_end,
    });
    try expectTokens(.json, "  42  ", &.{.{ .number = .{ .text = "42" } }});
    try expectTokens(.json, "\xEF\xBB\xBF[]", &.{ .array_begin, .array_end });
    try expectTokens(.json, "{}", &.{ .object_begin, .object_end });
}

test "escapes are decoded, and a string without any is not copied" {
    const text =
        \\["plain", "tab\tquote\"slash\/", "\u00e9\u4e2d", "\ud83d\ude00", "\ud800 lone"]
    ;
    var reader: Reader = .init(testing.allocator, text, .{});
    defer reader.deinit();
    _ = try reader.next();
    const plain = (try reader.next()).?.string;
    try testing.expect(plain.ptr == text[2..].ptr);
    try testing.expectEqualStrings("tab\tquote\"slash/", (try reader.next()).?.string);
    try testing.expectEqualStrings("é中", (try reader.next()).?.string);
    try testing.expectEqualStrings("😀", (try reader.next()).?.string);
    try testing.expectEqualStrings("\u{FFFD} lone", (try reader.next()).?.string);
}

test "numbers follow the grammar" {
    for ([_][]const u8{ "0", "-0", "12", "-12.5", "1e10", "1E+2", "1.5e-3", "0.0" }) |text| {
        try expectTokens(.json, text, &.{.{ .number = .{ .text = text } }});
    }
    try expectFailure(.json, "01", error.SyntaxError, "JSON numbers cannot have leading zeros: write 1");
    try expectFailure(.json, "-", error.SyntaxError, "expected a digit after '-'");
    try expectFailure(.json, "1.", error.SyntaxError, "expected a digit after the decimal point");
    try expectFailure(.json, "1e", error.SyntaxError, "expected a digit in the exponent");
    try expectFailure(.json, "12abc", error.SyntaxError, "'12abc' is not a number");
    try expectFailure(.json, ".5", error.SyntaxError, "a JSON number needs a digit before the '.': write 0.5, not .5");
    try expectFailure(.json, "+1", error.SyntaxError, "JSON numbers cannot start with '+' (JSON5 ones can)");
    try expectFailure(.json, "NaN", error.SyntaxError, "NaN is not a JSON number (JSON5 allows it)");
    try expectFailure(.json, "-Infinity", error.SyntaxError, "Infinity is not a JSON number (JSON5 allows it)");
}

test "mistakes get messages that say what to write instead" {
    try expectFailure(.json, "[1, 2,]", error.SyntaxError, "JSON does not allow a comma before ']' (.jsonc and .json5 do)");
    try expectFailure(.json, "{\"a\": 1,}", error.SyntaxError, "JSON does not allow a comma before '}' (.jsonc and .json5 do)");
    try expectFailure(.json, "{name: 1}", error.SyntaxError, "keys need double quotes in JSON: \"name\" (unquoted keys are JSON5)");
    try expectFailure(.json, "['x']", error.SyntaxError, "text needs double quotes in JSON, \"like this\" (single quotes are JSON5)");
    try expectFailure(.json, "[True]", error.SyntaxError, "JSON is case-sensitive: write true, not True");
    try expectFailure(.json, "[None]", error.SyntaxError, "JSON has no None: an empty value is written null");
    try expectFailure(.json, "[hello]", error.SyntaxError, "unexpected word 'hello': text needs double quotes, \"hello\"");
    try expectFailure(.json, "// hi\n1", error.SyntaxError, "JSON does not allow comments (.jsonc and .json5 do)");
    try expectFailure(.json, "{\"a\" 1}", error.SyntaxError, "expected ':' after the key, found '1'");
    try expectFailure(.json, "{\"a\": 1 \"b\": 2}", error.SyntaxError, "expected ',' or '}' after an object member, found '\"'");
    try expectFailure(.json, "[1 2]", error.SyntaxError, "expected ',' or ']' after an array item, found '2'");
    try expectFailure(.json, "[1}", error.SyntaxError, "expected ']' to close the array, found '}'");
    try expectFailure(.json, "{\"a\": 1]", error.SyntaxError, "expected '}' to close the object, found ']'");
    try expectFailure(.json, "[,1]", error.SyntaxError, "expected a value, found ','");
    try expectFailure(.json, "{\"a\":}", error.SyntaxError, "expected a value after ':', found '}'");
    try expectFailure(.json, "1 2", error.SyntaxError, "unexpected '2' after the end of the JSON value");
    try expectFailure(.json, "  ", error.SyntaxError, "there is no JSON value here: the text is empty");
    try expectFailure(.json, "\"abc", error.SyntaxError, "this string is never closed: its closing \" is missing");
    try expectFailure(.json, "\"a\nb\"", error.SyntaxError, "a string cannot hold a line break as it is: write \\n");
    try expectFailure(.json, "\"\\x41\"", error.SyntaxError, "'\\x' is not a JSON escape");
    try expectFailure(.json, "\"\\u12G4\"", error.SyntaxError, "expected 4 hex digits in this escape");
    try expectFailure(.json, "\"\xff\"", error.SyntaxError, "this is not UTF-8 text: byte 0xFF cannot be here");
    try expectFailure(.json, "\"\xed\xa0\x80\"", error.SyntaxError, "this is not UTF-8 text: byte 0xED starts a broken character");
}

test "a text that ends too soon says which bracket is still open" {
    try expectFailure(.json, "{\n  \"a\": [1,\n    2", error.SyntaxError, "the text ends before the array opened at line 2, column 8 is closed");
    try expectFailure(.json, "{\"a\":", error.SyntaxError, "the text ends where a value should follow ':'");
    try expectFailure(.json, "{\"a\"", error.SyntaxError, "the text ends after a key, where ':' and a value should follow");
    try expectFailure(.json, "{\"x\": \"}\", \"y\": [", error.SyntaxError, "the text ends before the array opened at line 1, column 17 is closed");
}

test "nesting deeper than the limit is refused" {
    var diagnostics: Diagnostics = .{};
    var reader: Reader = .init(testing.allocator, "[[[[1]]]]", .{ .max_depth = 3, .diagnostics = &diagnostics });
    defer reader.deinit();
    for (0..3) |_| _ = try reader.next();
    try testing.expectError(error.TooDeep, reader.next());
    try testing.expectEqualStrings("nested deeper than 3 levels", diagnostics.message());
}

test "jsonc allows comments and trailing commas, and nothing else" {
    try expectTokens(.jsonc,
        \\// settings
        \\{
        \\  "volume": 0.8, /* loud */
        \\  "keys": [1, 2,],
        \\}
    , &.{
        .object_begin,
        .{ .key = "volume" },
        .{ .number = .{ .text = "0.8" } },
        .{ .key = "keys" },
        .array_begin,
        .{ .number = .{ .text = "1" } },
        .{ .number = .{ .text = "2" } },
        .array_end,
        .object_end,
    });
    try expectFailure(.jsonc, "{a: 1}", error.SyntaxError, "keys need double quotes in JSON: \"a\" (unquoted keys are JSON5)");
    try expectFailure(.jsonc, "[1] /* open", error.SyntaxError, "this comment is never closed: its */ is missing");
    try expectFailure(.jsonc, "[1,,]", error.SyntaxError, "expected a value, found ','");
}

test "json5 reads everything the JSON5 spec adds" {
    try expectTokens(.json5,
        \\{
        \\  unquoted: 'and you can quote me on that',
        \\  singleQuotes: 'I can use "double quotes" here',
        \\  lineBreaks: "Look, Mom! \
        \\No \\n's!",
        \\  hexadecimal: 0xdecaf,
        \\  leadingDecimalPoint: .8675309, andTrailing: 8675309.,
        \\  positiveSign: +1,
        \\  trailingComma: 'in objects', andIn: ['arrays',],
        \\  "backwardsCompatible": "with JSON",
        \\  $dollar_key: Infinity, nan: -NaN,
        \\  escapes: '\x41\v\0\'',
        \\}
    , &.{
        .object_begin,
        .{ .key = "unquoted" },
        .{ .string = "and you can quote me on that" },
        .{ .key = "singleQuotes" },
        .{ .string = "I can use \"double quotes\" here" },
        .{ .key = "lineBreaks" },
        .{ .string = "Look, Mom! No \\n's!" },
        .{ .key = "hexadecimal" },
        .{ .number = .{ .text = "0xdecaf" } },
        .{ .key = "leadingDecimalPoint" },
        .{ .number = .{ .text = ".8675309" } },
        .{ .key = "andTrailing" },
        .{ .number = .{ .text = "8675309." } },
        .{ .key = "positiveSign" },
        .{ .number = .{ .text = "+1" } },
        .{ .key = "trailingComma" },
        .{ .string = "in objects" },
        .{ .key = "andIn" },
        .array_begin,
        .{ .string = "arrays" },
        .array_end,
        .{ .key = "backwardsCompatible" },
        .{ .string = "with JSON" },
        .{ .key = "$dollar_key" },
        .{ .number = .{ .text = "Infinity" } },
        .{ .key = "nan" },
        .{ .number = .{ .text = "-NaN" } },
        .{ .key = "escapes" },
        .{ .string = "A\x0b\x00'" },
        .object_end,
    });
    try expectTokens(.json5, "{\\u0061b: 1, café: 2}\u{00A0}", &.{
        .object_begin,
        .{ .key = "ab" },
        .{ .number = .{ .text = "1" } },
        .{ .key = "café" },
        .{ .number = .{ .text = "2" } },
        .object_end,
    });
}

test "peek looks without taking, and skipValue passes over a whole value" {
    var reader: Reader = .init(testing.allocator, "{\"skip\": {\"deep\": [1, {\"x\": \"\\n\"}]}, \"keep\": 7}", .{});
    defer reader.deinit();
    try testing.expectEqual(Kind.object_begin, (try reader.peek()).?);
    try testing.expectEqual(Kind.object_begin, (try reader.peek()).?);
    _ = try reader.next();
    try testing.expectEqualStrings("skip", (try reader.next()).?.key);
    try testing.expectEqual(Kind.object_begin, (try reader.peek()).?);
    try reader.skipValue();
    try testing.expectEqualStrings("keep", (try reader.next()).?.key);
    try reader.skipValue();
    try testing.expectEqual(Kind.object_end, std.meta.activeTag((try reader.next()).?));
    try testing.expectEqual(@as(?Kind, null), try reader.peek());
    try testing.expectEqual(@as(?Token, null), try reader.next());
}

test "location is the line and column of the last token" {
    var reader: Reader = .init(testing.allocator, "{\n  \"a\": [\n    true]}", .{});
    defer reader.deinit();
    for (0..4) |_| _ = try reader.next();
    try testing.expectEqual(Location{ .line = 3, .column = 5 }, reader.location());
}

test "CBOR reads as the tokens the same JSON would" {
    // {"a": [1, -2, 1.5, "x", h'fbff', true, null], "ab": {"cd": 1}}, the
    // keys "ab" and "cd" each in two parts and the last map of unknown length.
    try expectRead(.{}, &cbor.hex("d9d9f7 a2 6161 87 01 21 f93e00 6178 42fbff f5 f6 7f 6161 6162 ff bf 7f 6163 6164 ff 01 ff"), &.{
        .object_begin,
        .{ .key = "a" },
        .array_begin,
        .{ .number = .{ .text = "1" } },
        .{ .number = .{ .text = "-2" } },
        .{ .number = .{ .text = "1.5" } },
        .{ .string = "x" },
        .{ .string = "-_8" },
        .{ .bool = true },
        .null,
        .array_end,
        .{ .key = "ab" },
        .object_begin,
        .{ .key = "cd" },
        .{ .number = .{ .text = "1" } },
        .object_end,
        .object_end,
    });
}

test "CBOR is told from text by its tag, or read when it is named" {
    const counted: []const Token = &.{ .array_begin, .{ .number = .{ .text = "1" } }, .{ .number = .{ .text = "2" } }, .array_end };
    try expectRead(.{}, &cbor.hex("d9d9f7 82 01 02"), counted);
    try expectRead(.{ .format = .cbor }, &cbor.hex("82 01 02"), counted);
    _ = try readToError(.{}, &cbor.hex("82 01 02"), error.SyntaxError);
    _ = try readToError(.{ .format = .json }, &cbor.hex("d9d9f7 82 01 02"), error.SyntaxError);
}

test "CBOR mistakes say what is wrong, and at which byte" {
    try expectCborFailure("", "the CBOR ends before its value is complete", 0);
    try expectCborFailure(&cbor.hex("d9d9f7 82 01"), "the CBOR ends before the array opened at byte 3 is closed", 5);
    try expectCborFailure(&cbor.hex("a1 6161 63 6263"), "the CBOR ends before the map opened at byte 0 is closed", 6);
    try expectCborFailure(&cbor.hex("01 02"), "unexpected byte 0x02 after the end of the CBOR value", 1);
    try expectCborFailure(&cbor.hex("1c"), "byte 0x1C starts no CBOR item: additional information 28 is reserved", 0);
    try expectCborFailure(&cbor.hex("a1 01 02"), "a key must be text for JSON, and this map has a number as one", 1);
    try expectCborFailure(&cbor.hex("bf 6161 ff"), "this map ends between a key and its value", 3);
    try expectCborFailure(&cbor.hex("ff"), "a break (0xFF) with nothing open for it to close", 0);
    try expectCborFailure(&cbor.hex("82 01 ff"), "a break (0xFF) in an array of known length, which ends without one", 2);
    try expectCborFailure(&cbor.hex("62 c328"), "this is not UTF-8 text: byte 0xC3 starts a broken character", 1);
    try expectCborFailure(&cbor.hex("7f 6161 4162 ff"), "a text string of unknown length is made of text strings of known length, and this part is not", 3);
    try expectCborFailure(&cbor.hex("c2 4101"), "a big number (tag 2) has no JSON form here", 0);
    try expectCborFailure(&cbor.hex("f0"), "simple value 16 has no JSON form", 0);
    try expectCborFailure(&cbor.hex("1f"), "a number cannot be of indefinite length", 0);
    try expectCborFailure(&cbor.hex("df 01"), "a tag cannot be of indefinite length", 0);

    var diagnostics: Diagnostics = .{};
    var reader: Reader = .init(testing.allocator, &cbor.hex("81 81 81 81 01"), .{ .format = .cbor, .max_depth = 3, .diagnostics = &diagnostics });
    defer reader.deinit();
    for (0..3) |_| _ = try reader.next();
    try testing.expectError(error.TooDeep, reader.next());
    try testing.expectEqualStrings("nested deeper than 3 levels", diagnostics.message());
    try testing.expectEqual(@as(usize, 3), diagnostics.offset);
}

test "peek and skipValue work on CBOR as they do on text" {
    // {"skip": {"deep": [1, {"x": "\n"}]}, "keep": 7}
    var reader: Reader = .init(testing.allocator, &cbor.hex("d9d9f7 bf 64736b6970 a1 6464656570 9f 01 a1 6178 610a ff 646b656570 07 ff"), .{});
    defer reader.deinit();
    try testing.expectEqual(Kind.object_begin, (try reader.peek()).?);
    try testing.expectEqual(Kind.object_begin, (try reader.peek()).?);
    _ = try reader.next();
    try testing.expectEqualStrings("skip", (try reader.next()).?.key);
    try testing.expectEqual(Kind.object_begin, (try reader.peek()).?);
    try reader.skipValue();
    try testing.expectEqualStrings("keep", (try reader.next()).?.key);
    try reader.skipValue();
    try testing.expectEqual(Kind.object_end, std.meta.activeTag((try reader.next()).?));
    try testing.expectEqual(@as(?Kind, null), try reader.peek());
    try testing.expectEqual(@as(?Token, null), try reader.next());
}
