// SPDX-License-Identifier: CC0-1.0

const std = @import("std");
const math = std.math;
const testing = std.testing;

/// A number exactly as the text wrote it. Nothing is rounded until it is
/// asked for as a type, so `asInt(u64)` of `18446744073709551615` is exact.
pub const Number = struct {
    text: []const u8,

    /// Written without a fraction or an exponent: `12`, `-7`, and in JSON5 `0x1F`.
    pub fn isInteger(n: Number) bool {
        const body = unsigned(n.text);
        if (isHex(body)) return true;
        if (body.len == 0) return false;
        for (body) |c| if (!std.ascii.isDigit(c)) return false;
        return true;
    }

    /// As an integer of type `T`, or null when it is not a whole number or
    /// does not fit. `3.0` and `3e2` are whole numbers; `3.5` is not.
    pub fn asInt(n: Number, comptime T: type) ?T {
        const negative = n.text.len > 0 and n.text[0] == '-';
        const digits = n.text[@intFromBool(negative)..];
        if (digits.len > 0 and digits.len <= 18) {
            var magnitude: u64 = 0;
            for (digits) |c| {
                const digit = c -% '0';
                if (digit > 9) return n.asIntSlowly(T);
                magnitude = magnitude * 10 + digit;
            }
            if (!negative) return math.cast(T, magnitude);
            if (@typeInfo(T).int.signedness == .unsigned) return if (magnitude == 0) 0 else null;
            return math.cast(T, -@as(i64, @intCast(magnitude)));
        }
        return n.asIntSlowly(T);
    }

    fn asIntSlowly(n: Number, comptime T: type) ?T {
        if (n.isInteger()) return std.fmt.parseInt(T, n.text, 0) catch null;
        const f = n.asFloat(f64);
        if (!math.isFinite(f) or @floor(f) != f) return null;
        return floatToInt(T, f);
    }

    /// As a float of type `T`, rounded to the nearest one. A number too big
    /// for `T` becomes infinity, as it does everywhere else.
    pub fn asFloat(n: Number, comptime T: type) T {
        const negative = n.text.len > 0 and n.text[0] == '-';
        const body = unsigned(n.text);
        if (std.mem.eql(u8, body, "Infinity")) return if (negative) -math.inf(T) else math.inf(T);
        if (std.mem.eql(u8, body, "NaN")) return math.nan(T);
        return std.fmt.parseFloat(T, n.text) catch math.nan(T);
    }
};

/// Whether `text` is a number as JSON itself writes one, and not only as
/// JSON5 does.
pub fn isJson(text: []const u8) bool {
    var i: usize = @intFromBool(text.len > 0 and text[0] == '-');
    if (i >= text.len) return false;
    if (text[i] == '0') {
        i += 1;
    } else if (text[i] >= '1' and text[i] <= '9') {
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    } else return false;
    if (i < text.len and text[i] == '.') {
        i += 1;
        const digits = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i == digits) return false;
    }
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
        const digits = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i == digits) return false;
    }
    return i == text.len;
}

fn unsigned(text: []const u8) []const u8 {
    if (text.len > 0 and (text[0] == '-' or text[0] == '+')) return text[1..];
    return text;
}

fn isHex(body: []const u8) bool {
    return body.len > 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X');
}

/// `f` as a `T` if it is inside `T`'s range. The bounds are powers of two,
/// which a float holds exactly, so the maximum is never rounded up past itself.
pub fn floatToInt(comptime T: type, f: f64) ?T {
    const bits = @typeInfo(T).int.bits;
    const signed = @typeInfo(T).int.signedness == .signed;
    if (bits == 0) return if (f == 0) 0 else null;
    const limit = math.ldexp(@as(f64, 1), if (signed) bits - 1 else bits);
    const lowest: f64 = if (signed) -limit else 0;
    if (f < lowest or f >= limit) return null;
    return @as(T, @intFromFloat(f));
}

/// Enough room for `formatInt` to write any value of `T`.
pub fn maxIntLen(comptime T: type) usize {
    return @as(usize, @typeInfo(T).int.bits) * 30103 / 100000 + 3;
}

/// `value` in decimal, at the end of `buf`. Two digits a step, from a table.
pub fn formatInt(buf: []u8, value: anytype) []const u8 {
    const negative = @typeInfo(@TypeOf(value)).int.signedness == .signed and value < 0;
    var rest = @abs(value);
    var i = buf.len;
    while (rest >= 100) : (rest /= 100) {
        i -= 2;
        buf[i..][0..2].* = std.fmt.digits2(@intCast(rest % 100));
    }
    if (rest >= 10) {
        i -= 2;
        buf[i..][0..2].* = std.fmt.digits2(@intCast(rest));
    } else {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(rest));
    }
    if (negative) {
        i -= 1;
        buf[i] = '-';
    }
    return buf[i..];
}

/// Enough room for `formatFloat` to write any float, `f128` included.
pub const max_float_len = 64;

/// The shortest text that reads back as exactly `value`, laid out the way
/// JavaScript lays numbers out: `0.1`, `1234.5`, `1e+21`, `1e-7`. A whole
/// number keeps a `.0`, so it reads back as a float and not as an integer.
/// `value` must be finite.
pub fn formatFloat(buf: *[max_float_len]u8, value: anytype) []const u8 {
    var shortest: [max_float_len]u8 = undefined;
    const sci = std.fmt.float.render(&shortest, value, .{ .mode = .scientific }) catch unreachable;

    var digits: [48]u8 = undefined;
    var count: usize = 0;
    var i: usize = @intFromBool(sci[0] == '-');
    while (sci[i] != 'e') : (i += 1) {
        if (sci[i] == '.') continue;
        digits[count] = sci[i];
        count += 1;
    }
    const exponent = std.fmt.parseInt(i32, sci[i + 1 ..], 10) catch unreachable;
    const point = exponent + 1;

    var out: std.Io.Writer = .fixed(buf);
    if (sci[0] == '-') out.writeByte('-') catch unreachable;
    const all = digits[0..count];
    if (point >= 1 and point <= 21) {
        const whole: usize = @intCast(point);
        if (count <= whole) {
            out.writeAll(all) catch unreachable;
            out.splatByteAll('0', whole - count) catch unreachable;
            out.writeAll(".0") catch unreachable;
        } else {
            out.print("{s}.{s}", .{ all[0..whole], all[whole..] }) catch unreachable;
        }
    } else if (point > -6 and point <= 0) {
        out.writeAll("0.") catch unreachable;
        out.splatByteAll('0', @intCast(-point)) catch unreachable;
        out.writeAll(all) catch unreachable;
    } else {
        out.writeByte(all[0]) catch unreachable;
        if (count > 1) out.print(".{s}", .{all[1..]}) catch unreachable;
        out.print("e{c}{d}", .{ @as(u8, if (exponent < 0) '-' else '+'), @abs(exponent) }) catch unreachable;
    }
    return out.buffered();
}

fn expectFormat(expected: []const u8, value: anytype) !void {
    var buf: [max_float_len]u8 = undefined;
    try testing.expectEqualStrings(expected, formatFloat(&buf, value));
}

test "floats are written in the fewest digits, laid out as JavaScript does" {
    try expectFormat("0.0", @as(f64, 0));
    try expectFormat("-0.0", @as(f64, -0.0));
    try expectFormat("1.0", @as(f64, 1));
    try expectFormat("1.5", @as(f64, 1.5));
    try expectFormat("-1234.5", @as(f64, -1234.5));
    try expectFormat("0.1", @as(f64, 0.1));
    try expectFormat("0.000001", @as(f64, 1e-6));
    try expectFormat("1e-7", @as(f64, 1e-7));
    try expectFormat("1.5e-7", @as(f64, 1.5e-7));
    try expectFormat("100000000000000000000.0", @as(f64, 1e20));
    try expectFormat("1e+21", @as(f64, 1e21));
    try expectFormat("1.7976931348623157e+308", math.floatMax(f64));
    try expectFormat("5e-324", math.floatTrueMin(f64));
    try expectFormat("0.30000000000000004", @as(f64, 0.1) + @as(f64, 0.2));
}

test "integers of every width are written in full" {
    var buf: [maxIntLen(i128)]u8 = undefined;
    try testing.expectEqualStrings("0", formatInt(&buf, @as(u8, 0)));
    try testing.expectEqualStrings("7", formatInt(&buf, @as(i32, 7)));
    try testing.expectEqualStrings("-7", formatInt(&buf, @as(i32, -7)));
    try testing.expectEqualStrings("10", formatInt(&buf, @as(u32, 10)));
    try testing.expectEqualStrings("-100", formatInt(&buf, @as(i16, -100)));
    try testing.expectEqualStrings("255", formatInt(&buf, @as(u8, 255)));
    try testing.expectEqualStrings("-128", formatInt(&buf, @as(i8, -128)));
    try testing.expectEqualStrings("18446744073709551615", formatInt(&buf, @as(u64, math.maxInt(u64))));
    try testing.expectEqualStrings("-9223372036854775808", formatInt(&buf, @as(i64, math.minInt(i64))));
    try testing.expectEqualStrings("-170141183460469231731687303715884105728", formatInt(&buf, @as(i128, math.minInt(i128))));
    var prng = std.Random.DefaultPrng.init(7);
    for (0..10_000) |_| {
        const value = prng.random().int(i64);
        var expected: [32]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{d}", .{value}), formatInt(&buf, value));
    }
}

test "isJson knows JSON's own spelling of a number from JSON5's" {
    for ([_][]const u8{ "0", "-0", "12", "1.50", "1e2", "-1.5E-3" }) |text| try testing.expect(isJson(text));
    for ([_][]const u8{ "", "-", "01", "+1", ".5", "5.", "0x1F", "Infinity", "NaN", "1e", "1.e2" }) |text| try testing.expect(!isJson(text));
}

test "an f32 is written in its own shortest digits, not an f64's" {
    try expectFormat("0.1", @as(f32, 0.1));
    try expectFormat("16777216.0", @as(f32, 16777216));
    try expectFormat("3.4028235e+38", math.floatMax(f32));
}

test "every float reads back as itself" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    var buf: [max_float_len]u8 = undefined;
    for (0..20_000) |_| {
        const value: f64 = @bitCast(random.int(u64));
        if (!math.isFinite(value)) continue;
        const text = formatFloat(&buf, value);
        const back = (Number{ .text = text }).asFloat(f64);
        try testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(back)));
    }
    for (0..20_000) |_| {
        const value: f32 = @bitCast(random.int(u32));
        if (!math.isFinite(value)) continue;
        const text = formatFloat(&buf, value);
        const back = (Number{ .text = text }).asFloat(f32);
        try testing.expectEqual(@as(u32, @bitCast(value)), @as(u32, @bitCast(back)));
    }
}

test "asInt is exact for integers and accepts whole floats" {
    const n = struct {
        fn of(text: []const u8) Number {
            return .{ .text = text };
        }
    }.of;
    try testing.expectEqual(@as(?u64, math.maxInt(u64)), n("18446744073709551615").asInt(u64));
    try testing.expectEqual(@as(?i64, math.minInt(i64)), n("-9223372036854775808").asInt(i64));
    try testing.expectEqual(@as(?i64, null), n("9223372036854775808").asInt(i64));
    try testing.expectEqual(@as(?u8, null), n("256").asInt(u8));
    try testing.expectEqual(@as(?u8, null), n("-1").asInt(u8));
    try testing.expectEqual(@as(?i32, 300), n("3e2").asInt(i32));
    try testing.expectEqual(@as(?i32, 3), n("3.0").asInt(i32));
    try testing.expectEqual(@as(?i32, null), n("3.5").asInt(i32));
    try testing.expectEqual(@as(?i32, null), n("1e400").asInt(i32));
    try testing.expectEqual(@as(?i64, null), n("9.3e18").asInt(i64));
    try testing.expectEqual(@as(?i64, math.minInt(i64)), n("-9.223372036854775808e18").asInt(i64));
    try testing.expectEqual(@as(?i32, 31), n("0x1F").asInt(i32));
    try testing.expectEqual(@as(?i32, -31), n("-0x1f").asInt(i32));
    try testing.expectEqual(@as(?i32, 5), n("+5").asInt(i32));
}

test "asFloat reads the JSON5 spellings too" {
    const n = struct {
        fn of(text: []const u8) Number {
            return .{ .text = text };
        }
    }.of;
    try testing.expectEqual(math.inf(f64), n("Infinity").asFloat(f64));
    try testing.expectEqual(-math.inf(f64), n("-Infinity").asFloat(f64));
    try testing.expectEqual(math.inf(f32), n("+Infinity").asFloat(f32));
    try testing.expect(math.isNan(n("NaN").asFloat(f64)));
    try testing.expectEqual(@as(f64, 0.5), n(".5").asFloat(f64));
    try testing.expectEqual(@as(f64, 5), n("5.").asFloat(f64));
    try testing.expectEqual(@as(f64, 31), n("0x1F").asFloat(f64));
    try testing.expectEqual(math.inf(f32), n("1e39").asFloat(f32));
    try testing.expect(n("12").isInteger());
    try testing.expect(n("-0x10").isInteger());
    try testing.expect(!n("1.0").isInteger());
    try testing.expect(!n("1e3").isInteger());
    try testing.expect(!n("-Infinity").isInteger());
}
