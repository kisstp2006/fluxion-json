// SPDX-License-Identifier: CC0-1.0

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;

const number = @import("number.zig");
const Number = number.Number;
const Reader = @import("Reader.zig");
const Writer = @import("Writer.zig");
const Diagnostics = @import("Diagnostics.zig");
const encode = @import("encode.zig");
const decode = @import("decode.zig");

pub const EditError = error{ OutOfMemory, NotAnObject, NotAnArray, IndexOutOfBounds, TooDeep };

/// What to do with an object that has the same key twice.
pub const DuplicateKeys = enum {
    /// Keep the last value, in the place of the first, as JavaScript and
    /// Python do.
    last,
    first,
    /// Refuse the text with `error.DuplicateKey`.
    fail,
};

/// Any JSON value. An object or array is held by pointer, so copies of a
/// `Value` share it the way variables share an object in JavaScript or
/// Python: a change made through one copy is seen through all of them.
pub const Value = union(enum) {
    null,
    bool: bool,
    /// A number written without a fraction or an exponent that fits in 64
    /// bits. Every other number is a `float`, as it is in JavaScript.
    int: i64,
    float: f64,
    string: []const u8,
    array: *Array,
    object: *Object,

    /// A member of an object by name, or an item of an array by index, from
    /// the end when negative: `get("name")`, `get(0)`, `get(-1)`. Whatever is
    /// missing reads as `.null`, as does anything asked of a value that is
    /// not an object or an array, so lookups chain safely:
    /// `root.get("player").get("inventory").get(0).get("name")`.
    pub fn get(v: Value, key: anytype) Value {
        switch (@typeInfo(@TypeOf(key))) {
            .int, .comptime_int => return switch (v) {
                .array => |a| a.get(key),
                else => .null,
            },
            else => return switch (v) {
                .object => |o| o.get(key),
                else => .null,
            },
        }
    }

    /// Where a JSON Pointer (RFC 6901) leads, such as `"/player/items/0"`,
    /// or `.null` if nowhere. The leading slash may be left out.
    pub fn at(v: Value, pointer: []const u8) Value {
        if (pointer.len == 0) return v;
        const rest = if (pointer[0] == '/') pointer[1..] else pointer;
        var current = v;
        var segments = std.mem.splitScalar(u8, rest, '/');
        while (segments.next()) |segment| {
            current = switch (current) {
                .object => |o| o.getEscaped(segment),
                .array => |a| a.get(pointerIndex(segment) orelse return .null),
                else => return .null,
            };
        }
        return current;
    }

    /// Whether this is an object with a member called `key`.
    pub fn has(v: Value, key: []const u8) bool {
        return switch (v) {
            .object => |o| o.has(key),
            else => false,
        };
    }

    /// Items in an array or members in an object; 0 for anything else.
    pub fn len(v: Value) usize {
        return switch (v) {
            .array => |a| a.len(),
            .object => |o| o.len(),
            else => 0,
        };
    }

    /// An array's items, or none: `for (root.get("enemies").items()) |enemy|`.
    pub fn items(v: Value) []Value {
        return switch (v) {
            .array => |a| a.items(),
            else => &no_values,
        };
    }

    /// An object's keys in order, or none.
    pub fn keys(v: Value) []const []const u8 {
        return switch (v) {
            .object => |o| o.keys(),
            else => &.{},
        };
    }

    /// An object's values in the order of `keys`, or none.
    pub fn values(v: Value) []Value {
        return switch (v) {
            .object => |o| o.values(),
            else => &no_values,
        };
    }

    pub fn asBool(v: Value) ?bool {
        return switch (v) {
            .bool => |b| b,
            else => null,
        };
    }

    /// The number as a `T` if it is a whole number that fits: `3` and
    /// `3.0` are, `3.5` and `300` as a `u8` are not.
    pub fn asInt(v: Value, comptime T: type) ?T {
        return switch (v) {
            .int => |i| math.cast(T, i),
            .float => |f| if (math.isFinite(f) and @floor(f) == f) number.floatToInt(T, f) else null,
            else => null,
        };
    }

    pub fn asFloat(v: Value, comptime T: type) ?T {
        return switch (v) {
            .int => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            else => null,
        };
    }

    pub fn asString(v: Value) ?[]const u8 {
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    /// A string naming a member of `E`, or a number one of them stands for.
    pub fn asEnum(v: Value, comptime E: type) ?E {
        return switch (v) {
            .string => |s| std.meta.stringToEnum(E, s),
            .int => |i| std.enums.fromInt(E, i),
            else => null,
        };
    }

    pub fn asArray(v: Value) ?*Array {
        return switch (v) {
            .array => |a| a,
            else => null,
        };
    }

    pub fn asObject(v: Value) ?*Object {
        return switch (v) {
            .object => |o| o,
            else => null,
        };
    }

    /// `"null"`, `"boolean"`, `"number"`, `"string"`, `"array"` or `"object"`,
    /// as JavaScript's `typeof` would say it.
    pub fn typeName(v: Value) []const u8 {
        return switch (v) {
            .null => "null",
            .bool => "boolean",
            .int, .float => "number",
            .string => "string",
            .array => "array",
            .object => "object",
        };
    }

    /// Set a member of this object. See `Object.put`.
    pub fn put(v: Value, key: []const u8, value: anytype) EditError!void {
        const o = v.asObject() orelse return error.NotAnObject;
        return o.put(key, value);
    }

    /// Add an item to the end of this array. See `Array.append`.
    pub fn append(v: Value, value: anytype) EditError!void {
        const a = v.asArray() orelse return error.NotAnArray;
        return a.append(value);
    }

    /// Take a member out of an object by name, or an item out of an array by
    /// index. Whether there was one to take.
    pub fn remove(v: Value, key: anytype) bool {
        switch (@typeInfo(@TypeOf(key))) {
            .int, .comptime_int => {
                const a = v.asArray() orelse return false;
                const index = resolveIndex(a.len(), key) orelse return false;
                _ = a.list.orderedRemove(index);
                return true;
            },
            else => {
                const o = v.asObject() orelse return false;
                return o.remove(key);
            },
        }
    }

    /// Whether two values hold the same JSON. Numbers compare by value, so
    /// `1` equals `1.0`; objects compare by members, in any order.
    pub fn eql(a: Value, b: Value) bool {
        return eqlDepth(a, b, 0);
    }

    /// Convert this value into a `T`, as `parseAs` does text. The result has
    /// its own memory and outlives the document this value is in.
    pub fn parseAs(v: Value, comptime T: type, gpa: Allocator, options: decode.Options) decode.Error!decode.Parsed(T) {
        return decode.parseValueAs(T, gpa, v, options);
    }

    /// Compact JSON, for `{f}`. Use `json.fmt` to indent it.
    pub fn format(v: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var writer: Writer = .init(w, .{});
        writer.write(v) catch return error.WriteFailed;
    }
};

var no_values: [0]Value = .{};

pub const Array = struct {
    list: std.ArrayListUnmanaged(Value) = .empty,
    arena: *ArenaAllocator,

    pub fn items(a: *const Array) []Value {
        return a.list.items;
    }

    pub fn len(a: *const Array) usize {
        return a.list.items.len;
    }

    /// The item at `index`, from the end when negative, or `.null`.
    pub fn get(a: *const Array, index: anytype) Value {
        return a.list.items[resolveIndex(a.len(), index) orelse return .null];
    }

    /// Add to the end. `value` may be a `Value` or any Zig value: `3`,
    /// `"text"`, `.{ .x = 1, .y = 2 }`, a slice, a struct. A Zig value is
    /// copied in; a `Value` from this document is shared, and one from
    /// another document copied.
    pub fn append(a: *Array, value: anytype) EditError!void {
        const converted = try toValue(a.arena, value);
        try a.list.append(a.arena.allocator(), converted);
    }

    /// Insert at `index`, moving what follows along. `index` may be `len()`.
    pub fn insert(a: *Array, index: usize, value: anytype) EditError!void {
        if (index > a.len()) return error.IndexOutOfBounds;
        const converted = try toValue(a.arena, value);
        try a.list.insert(a.arena.allocator(), index, converted);
    }

    /// Replace the item at `index`.
    pub fn set(a: *Array, index: usize, value: anytype) EditError!void {
        if (index >= a.len()) return error.IndexOutOfBounds;
        a.list.items[index] = try toValue(a.arena, value);
    }

    /// Take out the item at `index`, closing the gap. Whether there was one.
    pub fn remove(a: *Array, index: usize) bool {
        if (index >= a.len()) return false;
        _ = a.list.orderedRemove(index);
        return true;
    }

    /// Take out the last item.
    pub fn pop(a: *Array) ?Value {
        return a.list.pop();
    }

    pub fn clear(a: *Array) void {
        a.list.clearRetainingCapacity();
    }
};

pub const Object = struct {
    map: std.array_hash_map.String(Value) = .empty,
    arena: *ArenaAllocator,

    /// The member called `key`, or `.null`. Use `has` or `getPtr` to tell a
    /// missing member from one that is `null`.
    pub fn get(o: *const Object, key: []const u8) Value {
        return o.map.get(key) orelse .null;
    }

    /// The member called `key`, to change in place.
    pub fn getPtr(o: *const Object, key: []const u8) ?*Value {
        return o.map.getPtr(key);
    }

    pub fn has(o: *const Object, key: []const u8) bool {
        return o.map.contains(key);
    }

    pub fn len(o: *const Object) usize {
        return o.map.count();
    }

    /// Keys in the order they were written or added.
    pub fn keys(o: *const Object) []const []const u8 {
        return o.map.keys();
    }

    /// Values in the order of `keys`: `for (o.keys(), o.values()) |key, value|`.
    pub fn values(o: *const Object) []Value {
        return o.map.values();
    }

    /// Set the member called `key`, replacing it where it stands or adding it
    /// at the end. `value` may be a `Value` or any Zig value; see
    /// `Array.append`. The key is copied.
    pub fn put(o: *Object, key: []const u8, value: anytype) EditError!void {
        try o.putValue(key, try toValue(o.arena, value));
    }

    /// Take out the member called `key`, keeping the others in order.
    pub fn remove(o: *Object, key: []const u8) bool {
        return o.map.orderedRemove(key);
    }

    pub fn clear(o: *Object) void {
        o.map.clearRetainingCapacity();
    }

    /// Apply `patch` as a JSON Merge Patch (RFC 7386): each of its members
    /// replaces or adds the member of the same name, recursing into objects,
    /// and a `null` removes it. User settings over defaults, in one call.
    pub fn merge(o: *Object, patch: Value) EditError!void {
        if (patch != .object) return error.NotAnObject;
        _ = try mergeInto(o.arena, .{ .object = o }, patch, 0);
    }

    fn putValue(o: *Object, key: []const u8, value: Value) Allocator.Error!void {
        if (o.map.getPtr(key)) |slot| {
            slot.* = value;
            return;
        }
        const memory = o.arena.allocator();
        try o.map.put(memory, try memory.dupe(u8, key), value);
    }

    /// A member by a JSON Pointer segment, in which `~1` stands for `/` and
    /// `~0` for `~`.
    fn getEscaped(o: *const Object, segment: []const u8) Value {
        if (std.mem.indexOfScalar(u8, segment, '~') == null) return o.get(segment);
        for (o.map.keys(), o.map.values()) |key, value| {
            if (pointerSegmentIs(segment, key)) return value;
        }
        return .null;
    }
};

fn pointerSegmentIs(segment: []const u8, key: []const u8) bool {
    var i: usize = 0;
    var k: usize = 0;
    while (i < segment.len) : (k += 1) {
        if (k >= key.len) return false;
        var c = segment[i];
        i += 1;
        if (c == '~' and i < segment.len) {
            c = switch (segment[i]) {
                '0' => '~',
                '1' => '/',
                else => return false,
            };
            i += 1;
        }
        if (key[k] != c) return false;
    }
    return k == key.len;
}

fn pointerIndex(segment: []const u8) ?usize {
    if (segment.len == 0 or (segment.len > 1 and segment[0] == '0')) return null;
    for (segment) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(usize, segment, 10) catch null;
}

fn resolveIndex(len: usize, index: anytype) ?usize {
    const I = @TypeOf(index);
    if (@typeInfo(I) != .int and @typeInfo(I) != .comptime_int) @compileError("an array index is an integer, not " ++ @typeName(I));
    if (index < 0) {
        const back = math.cast(usize, -@as(i128, index)) orelse return null;
        return if (back <= len) len - back else null;
    }
    const forward = math.cast(usize, index) orelse return null;
    return if (forward < len) forward else null;
}

fn eqlDepth(a: Value, b: Value, depth: usize) bool {
    if (depth > Reader.max_depth_limit) return false;
    switch (a) {
        .null => return b == .null,
        .bool => |x| return b == .bool and b.bool == x,
        .int, .float => return numbersEqual(a, b),
        .string => |s| return b == .string and std.mem.eql(u8, s, b.string),
        .array => |x| {
            if (b != .array) return false;
            if (x == b.array) return true;
            if (x.len() != b.array.len()) return false;
            for (x.items(), b.array.items()) |p, q| if (!eqlDepth(p, q, depth + 1)) return false;
            return true;
        },
        .object => |x| {
            if (b != .object) return false;
            if (x == b.object) return true;
            if (x.len() != b.object.len()) return false;
            for (x.keys(), x.values()) |key, value| {
                const other = b.object.map.get(key) orelse return false;
                if (!eqlDepth(value, other, depth + 1)) return false;
            }
            return true;
        },
    }
}

fn numbersEqual(a: Value, b: Value) bool {
    if (a == .int and b == .int) return a.int == b.int;
    if (a == .float and b == .float) return a.float == b.float;
    const int = if (a == .int) a.int else if (b == .int) b.int else return false;
    const float: Value = if (a == .float) a else if (b == .float) b else return false;
    const whole = float.asInt(i64) orelse return false;
    return whole == int;
}

/// `value` as a `Value` living in `arena`: a `Value` from the same arena as
/// it is, one from another arena copied, and a Zig value converted.
pub fn toValue(arena: *ArenaAllocator, value: anytype) EditError!Value {
    const T = @TypeOf(value);
    if (T == Value) return adopt(arena, value);
    if (T == *Object) return adopt(arena, .{ .object = value });
    if (T == *Array) return adopt(arena, .{ .array = value });
    return build(arena, value);
}

fn adopt(arena: *ArenaAllocator, v: Value) EditError!Value {
    return switch (v) {
        .string => |s| .{ .string = try arena.allocator().dupe(u8, s) },
        .array => |a| if (a.arena == arena) v else build(arena, v),
        .object => |o| if (o.arena == arena) v else build(arena, v),
        else => v,
    };
}

/// A deep copy of any Zig value, `Value`s included, in `arena`.
pub fn build(arena: *ArenaAllocator, value: anytype) EditError!Value {
    var builder: Builder = .{ .arena = arena };
    defer builder.deinit();
    var writer: Writer = .initTree(&builder);
    writer.write(value) catch |err| return switch (err) {
        error.OutOfMemory, error.TooDeep => |e| e,
        error.WriteFailed, error.NonFiniteNumber => unreachable,
    };
    return builder.root orelse .null;
}

pub fn mergeInto(arena: *ArenaAllocator, target: Value, patch: Value, depth: usize) EditError!Value {
    if (patch != .object) return adopt(arena, patch);
    if (depth > Reader.max_depth_limit) return error.TooDeep;
    const object = switch (target) {
        .object => |o| o,
        else => try newObject(arena),
    };
    for (patch.object.keys(), patch.object.values()) |key, value| {
        if (value == .null) {
            _ = object.remove(key);
            continue;
        }
        try object.putValue(key, try mergeInto(arena, object.get(key), value, depth + 1));
    }
    return .{ .object = object };
}

pub fn newObject(arena: *ArenaAllocator) Allocator.Error!*Object {
    const object = try arena.allocator().create(Object);
    object.* = .{ .arena = arena };
    return object;
}

pub fn newArray(arena: *ArenaAllocator) Allocator.Error!*Array {
    const array = try arena.allocator().create(Array);
    array.* = .{ .arena = arena };
    return array;
}

/// A number as a `Value`: an `int` when it is written as an integer and fits
/// in 64 bits, and a `float` otherwise. `-0` stays a float so its sign is kept.
pub fn numberValue(n: Number) Value {
    if (n.isInteger() and !std.mem.eql(u8, n.text, "-0")) {
        if (n.asInt(i64)) |i| return .{ .int = i };
    }
    return .{ .float = n.asFloat(f64) };
}

/// Puts a tree together from begin, key, value and end, holding the pieces of
/// every open container on shared stacks. Each container is made once, at
/// its end, at its final size, so nothing in the arena is outgrown and left
/// behind.
pub const Builder = struct {
    arena: *ArenaAllocator,
    duplicates: DuplicateKeys = .last,
    diagnostics: ?*Diagnostics = null,
    source: []const u8 = "",
    values: std.ArrayListUnmanaged(Value) = .empty,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    frames: std.ArrayListUnmanaged(Frame) = .empty,
    /// A string arriving in parts, gathered until it ends.
    parts: std.ArrayListUnmanaged(u8) = .empty,
    root: ?Value = null,

    const Frame = struct {
        is_object: bool,
        first_value: usize,
        first_name: usize,
        start: usize,
    };

    pub fn deinit(b: *Builder) void {
        const gpa = b.arena.child_allocator;
        b.values.deinit(gpa);
        b.names.deinit(gpa);
        b.frames.deinit(gpa);
        b.parts.deinit(gpa);
    }

    pub fn begin(b: *Builder, is_object: bool, start: usize) Allocator.Error!void {
        try b.frames.append(b.arena.child_allocator, .{
            .is_object = is_object,
            .first_value = b.values.items.len,
            .first_name = b.names.items.len,
            .start = start,
        });
    }

    pub fn key(b: *Builder, name: []const u8) Allocator.Error!void {
        try b.names.append(b.arena.child_allocator, try b.arena.allocator().dupe(u8, name));
    }

    pub fn string(b: *Builder, text: []const u8) Allocator.Error!void {
        try b.add(.{ .string = try b.arena.allocator().dupe(u8, text) });
    }

    pub fn stringPart(b: *Builder, part: []const u8) Allocator.Error!void {
        try b.parts.appendSlice(b.arena.child_allocator, part);
    }

    pub fn endString(b: *Builder) Allocator.Error!void {
        defer b.parts.clearRetainingCapacity();
        try b.string(b.parts.items);
    }

    /// Add a value that owns no memory, or whose memory is already in the arena.
    pub fn add(b: *Builder, value: Value) Allocator.Error!void {
        if (b.frames.items.len == 0) {
            b.root = value;
            return;
        }
        try b.values.append(b.arena.child_allocator, value);
    }

    pub fn end(b: *Builder) error{ OutOfMemory, DuplicateKey }!void {
        const frame = b.frames.pop().?;
        const children = b.values.items[frame.first_value..];
        const container: Value = if (frame.is_object) blk: {
            const object = try newObject(b.arena);
            try object.map.ensureTotalCapacity(b.arena.allocator(), children.len);
            for (b.names.items[frame.first_name..], children) |name, child| {
                const slot = object.map.getOrPutAssumeCapacity(name);
                if (!slot.found_existing) {
                    slot.value_ptr.* = child;
                    continue;
                }
                switch (b.duplicates) {
                    .last => slot.value_ptr.* = child,
                    .first => {},
                    .fail => return b.duplicate(name, frame.start),
                }
            }
            b.names.shrinkRetainingCapacity(frame.first_name);
            break :blk .{ .object = object };
        } else blk: {
            const array = try newArray(b.arena);
            try array.list.ensureTotalCapacityPrecise(b.arena.allocator(), children.len);
            array.list.appendSliceAssumeCapacity(children);
            break :blk .{ .array = array };
        };
        b.values.shrinkRetainingCapacity(frame.first_value);
        try b.add(container);
    }

    fn duplicate(b: *Builder, name: []const u8, start: usize) error{DuplicateKey} {
        if (b.diagnostics) |d| {
            if (b.source.len > 0) d.setPlace(b.source, start) else d.setNoPlace();
            d.setMessage("the key \"{s}\" appears more than once in this object", .{name});
            d.path_len = 0;
        }
        return error.DuplicateKey;
    }
};

pub const ReadError = error{ SyntaxError, TooDeep, OutOfMemory, DuplicateKey };

/// Read the next whole value from `reader` into a tree in `arena`.
pub fn readValue(reader: *Reader, arena: *ArenaAllocator, duplicates: DuplicateKeys) ReadError!Value {
    var b: Builder = .{
        .arena = arena,
        .duplicates = duplicates,
        .diagnostics = reader.diagnostics,
        .source = reader.input,
    };
    defer b.deinit();
    return feed(&b, reader);
}

/// Carry on reading tokens into `b` until the value it is building is whole.
pub fn feed(b: *Builder, reader: *Reader) ReadError!Value {
    while (try reader.next()) |token| {
        switch (token) {
            .object_begin => try b.begin(true, reader.token_start),
            .array_begin => try b.begin(false, reader.token_start),
            .object_end, .array_end => try b.end(),
            .key => |name| try b.key(name),
            .string => |text| try b.string(text),
            .number => |n| try b.add(numberValue(n)),
            .bool => |v| try b.add(.{ .bool = v }),
            .null => try b.add(.null),
        }
        if (b.frames.items.len == 0) return b.root.?;
    }
    return error.SyntaxError;
}

const TestDoc = struct {
    arena: *ArenaAllocator,
    root: Value,

    fn init(text: []const u8) !TestDoc {
        const arena = try testing.allocator.create(ArenaAllocator);
        arena.* = .init(testing.allocator);
        errdefer {
            arena.deinit();
            testing.allocator.destroy(arena);
        }
        var reader: Reader = .init(testing.allocator, text, .{});
        defer reader.deinit();
        return .{ .arena = arena, .root = try readValue(&reader, arena, .last) };
    }

    fn deinit(d: *TestDoc) void {
        d.arena.deinit();
        testing.allocator.destroy(d.arena);
    }
};

test "lookups chain, and whatever is missing reads as null" {
    var doc: TestDoc = try .init(
        \\{"player": {"name": "Ada", "hp": 30, "items": [{"name": "sword"}, {"name": "bow"}]}}
    );
    defer doc.deinit();
    const player = doc.root.get("player");
    try testing.expectEqualStrings("Ada", player.get("name").asString().?);
    try testing.expectEqual(@as(?u8, 30), player.get("hp").asInt(u8));
    try testing.expectEqualStrings("bow", player.get("items").get(1).get("name").asString().?);
    try testing.expectEqualStrings("bow", player.get("items").get(-1).get("name").asString().?);
    try testing.expectEqual(Value.null, player.get("items").get(2));
    try testing.expectEqual(Value.null, player.get("items").get(-3));
    try testing.expectEqual(Value.null, doc.root.get("nobody").get("name").get(0));
    try testing.expectEqual(@as(u16, 99), doc.root.get("nobody").get("hp").asInt(u16) orelse 99);
    try testing.expectEqual(@as(usize, 2), player.get("items").len());
    try testing.expectEqual(@as(usize, 0), player.get("name").items().len);
}

test "at follows a JSON Pointer, escapes and all" {
    var doc: TestDoc = try .init(
        \\{"a/b": {"m~n": [10, 20]}, "": 1, "list": [0, 1, 2]}
    );
    defer doc.deinit();
    try testing.expectEqual(@as(?i32, 20), doc.root.at("/a~1b/m~0n/1").asInt(i32));
    try testing.expectEqual(@as(?i32, 1), doc.root.at("/").asInt(i32));
    try testing.expectEqual(@as(?i32, 2), doc.root.at("list/2").asInt(i32));
    try testing.expect(doc.root.at("").eql(doc.root));
    try testing.expectEqual(Value.null, doc.root.at("/list/01"));
    try testing.expectEqual(Value.null, doc.root.at("/list/-"));
    try testing.expectEqual(Value.null, doc.root.at("/list/9"));
    try testing.expectEqual(Value.null, doc.root.at("/a~2b"));
}

test "numbers keep what kind of number they were written as" {
    var doc: TestDoc = try .init("[1, -0, 1.0, 1e2, 9223372036854775807, 9223372036854775808, -9223372036854775808]");
    defer doc.deinit();
    const items = doc.root.items();
    try testing.expectEqual(Value{ .int = 1 }, items[0]);
    try testing.expect(items[1] == .float and math.signbit(items[1].float));
    try testing.expectEqual(Value{ .float = 1 }, items[2]);
    try testing.expectEqual(Value{ .float = 100 }, items[3]);
    try testing.expectEqual(Value{ .int = math.maxInt(i64) }, items[4]);
    try testing.expectEqual(Value{ .float = 9223372036854775808.0 }, items[5]);
    try testing.expectEqual(Value{ .int = math.minInt(i64) }, items[6]);
    try testing.expectEqual(@as(?u8, 100), items[3].asInt(u8));
    try testing.expectEqual(@as(?u8, null), (Value{ .float = 1.5 }).asInt(u8));
    try testing.expectEqual(@as(?f32, 1), items[0].asFloat(f32));
}

test "duplicate keys keep the last value in the first place, unless told otherwise" {
    var doc: TestDoc = try .init("{\"a\": 1, \"b\": 2, \"a\": 3}");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.root.len());
    try testing.expectEqualStrings("a", doc.root.keys()[0]);
    try testing.expectEqual(@as(?i32, 3), doc.root.get("a").asInt(i32));

    const arena = try testing.allocator.create(ArenaAllocator);
    arena.* = .init(testing.allocator);
    defer {
        arena.deinit();
        testing.allocator.destroy(arena);
    }
    var diagnostics: Diagnostics = .{};
    var reader: Reader = .init(testing.allocator, "[{\"a\": 1, \"a\": 2}]", .{ .diagnostics = &diagnostics });
    defer reader.deinit();
    try testing.expectError(error.DuplicateKey, readValue(&reader, arena, .fail));
    try testing.expectEqualStrings("the key \"a\" appears more than once in this object", diagnostics.message());
    try testing.expectEqual(@as(u32, 2), diagnostics.column);
}

test "copies of a value share its objects, as in JavaScript" {
    var doc: TestDoc = try .init("{\"player\": {\"hp\": 10}, \"list\": []}");
    defer doc.deinit();
    const player = doc.root.get("player");
    try player.put("hp", 11);
    try player.put("name", "Ada");
    try testing.expectEqual(@as(?i32, 11), doc.root.get("player").get("hp").asInt(i32));
    try testing.expectEqualStrings("hp", doc.root.get("player").keys()[0]);
    try testing.expectEqualStrings("name", doc.root.get("player").keys()[1]);

    const list = doc.root.get("list");
    try list.append(1);
    try list.append("two");
    try list.append(.{ .x = 3, .tags = .{ "a", "b" } });
    try list.append(player);
    try testing.expectEqual(@as(usize, 4), doc.root.get("list").len());
    try testing.expectEqualStrings("b", doc.root.at("/list/2/tags/1").asString().?);
    try player.put("hp", 12);
    try testing.expectEqual(@as(?i32, 12), doc.root.at("/list/3/hp").asInt(i32));

    try testing.expectError(error.NotAnArray, player.append(1));
    try testing.expectError(error.NotAnObject, list.put("x", 1));
    try testing.expect(list.remove(0));
    try testing.expect(list.remove(-1));
    try testing.expect(!list.remove(5));
    try testing.expect(doc.root.remove("player"));
    try testing.expect(!doc.root.remove("player"));
    try testing.expectEqual(@as(usize, 1), doc.root.len());
}

test "a value from another document is copied in, not shared" {
    var first: TestDoc = try .init("{\"a\": {\"b\": [1, 2]}}");
    defer first.deinit();
    {
        var second: TestDoc = try .init("{}");
        defer second.deinit();
        try first.root.put("copied", second.root);
        try second.root.put("later", true);
        try first.root.put("nested", second.root);
    }
    try testing.expect(first.root.get("copied").asObject() != null);
    try testing.expectEqual(@as(usize, 0), first.root.get("copied").len());
    try testing.expectEqual(Value{ .bool = true }, first.root.at("/nested/later"));
}

test "eql compares JSON, not bytes" {
    var a: TestDoc = try .init("{\"x\": 1, \"y\": [true, null, \"s\"], \"z\": {\"q\": 2.5}}");
    defer a.deinit();
    var b: TestDoc = try .init("{\"z\": {\"q\": 2.5}, \"y\": [true, null, \"s\"], \"x\": 1.0}");
    defer b.deinit();
    var c: TestDoc = try .init("{\"z\": {\"q\": 2.5}, \"y\": [true, null, \"t\"], \"x\": 1.0}");
    defer c.deinit();
    try testing.expect(a.root.eql(b.root));
    try testing.expect(!a.root.eql(c.root));
    try testing.expect(!(Value{ .int = 1 }).eql(.{ .float = 1.5 }));
    try testing.expect(!(Value{ .int = 1 }).eql(.{ .bool = true }));
}

test "merge lays a patch over defaults" {
    var defaults: TestDoc = try .init(
        \\{"audio": {"volume": 0.8, "muted": false}, "video": {"width": 1280}, "name": "x"}
    );
    defer defaults.deinit();
    var user: TestDoc = try .init(
        \\{"audio": {"volume": 0.5}, "video": null, "name": {"first": "Ada"}}
    );
    defer user.deinit();
    try defaults.root.asObject().?.merge(user.root);
    var expected: TestDoc = try .init(
        \\{"audio": {"volume": 0.5, "muted": false}, "name": {"first": "Ada"}}
    );
    defer expected.deinit();
    try testing.expect(defaults.root.eql(expected.root));
}

test "asEnum reads a member's name or its number" {
    const Difficulty = enum(u8) { easy, normal, hard };
    try testing.expectEqual(Difficulty.hard, (Value{ .string = "hard" }).asEnum(Difficulty).?);
    try testing.expectEqual(Difficulty.normal, (Value{ .int = 1 }).asEnum(Difficulty).?);
    try testing.expectEqual(@as(?Difficulty, null), (Value{ .string = "Hard" }).asEnum(Difficulty));
    try testing.expectEqual(@as(?Difficulty, null), (Value{ .int = 7 }).asEnum(Difficulty));
}
