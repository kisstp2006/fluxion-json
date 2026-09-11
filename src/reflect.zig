// SPDX-License-Identifier: CC0-1.0

//! What a Zig type looks like as JSON, worked out at compile time and shared
//! by reading and writing so the two cannot disagree.
//!
//! A struct, union or enum can shape its JSON with declarations:
//!
//! ```zig
//! pub const json_case = .camel;                        // byte_offset <-> "byteOffset"
//! pub const json_rename = .{ .kind = "type" };         // one field, any name
//! pub const json_ignore = .{ .cache };                 // never read or written
//! pub const json_tag = "type";                         // unions: {"type": "circle", ...}
//! pub fn toJson(self: T, w: *json.Writer) json.Writer.Error!void
//! pub fn fromJson(value: json.Value, allocator: std.mem.Allocator) json.Error!T
//! ```

const std = @import("std");
const testing = std.testing;

const Value = @import("value.zig").Value;

pub const Case = enum {
    /// `byte_offset` is `"byteOffset"`.
    camel,
    /// `byte_offset` is `"ByteOffset"`.
    pascal,
    /// `byte_offset` is `"byte-offset"`.
    kebab,
};

/// The key a field, union arm or enum member is written as.
pub fn jsonName(comptime T: type, comptime name: []const u8) []const u8 {
    return comptime blk: {
        check(T);
        if (@hasDecl(T, "json_rename") and @hasField(@TypeOf(T.json_rename), name)) break :blk @field(T.json_rename, name);
        if (@hasDecl(T, "json_case")) break :blk convertCase(name, T.json_case);
        break :blk name;
    };
}

pub fn isIgnored(comptime T: type, comptime name: []const u8) bool {
    return comptime blk: {
        if (!@hasDecl(T, "json_ignore")) break :blk false;
        for (T.json_ignore) |ignored| if (std.mem.eql(u8, @tagName(ignored), name)) break :blk true;
        break :blk false;
    };
}

/// The key naming a union's arm inside the payload's own object, if the
/// union is written that way.
pub fn tagKey(comptime T: type) ?[]const u8 {
    return if (@hasDecl(T, "json_tag")) T.json_tag else null;
}

pub fn hasHook(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

/// A `std.ArrayList` or `std.array_list.Managed`: written as its items.
pub fn isArrayList(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct" or !@hasField(T, "items") or !@hasField(T, "capacity")) return false;
    const items = @typeInfo(@FieldType(T, "items"));
    if (items != .pointer or items.pointer.size != .slice) return false;
    const fields = info.@"struct".fields.len;
    return fields == 2 or (fields == 3 and @hasField(T, "allocator"));
}

pub const MapKind = enum {
    /// Keeps insertion order, like `std.StringArrayHashMapUnmanaged`.
    ordered,
    /// No order of its own, like `std.StringHashMap`.
    unordered,
};

/// A standard library map with string keys: written as an object.
pub fn mapKind(comptime T: type) ?MapKind {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "KV") or !@hasDecl(T, "iterator")) return null;
    if (!@hasField(T.KV, "key") or @FieldType(T.KV, "key") != []const u8) return null;
    return if (@hasDecl(T, "keys") and @hasDecl(T, "values")) .ordered else .unordered;
}

pub fn MapValue(comptime T: type) type {
    return @FieldType(T.KV, "value");
}

/// Field indexes in declaration order, or in the alphabetical order of the
/// names they are written as.
pub fn fieldOrder(comptime T: type, comptime sorted: bool) *const [@typeInfo(T).@"struct".fields.len]usize {
    return comptime blk: {
        const fields = @typeInfo(T).@"struct".fields;
        @setEvalBranchQuota(100_000);
        var order: [fields.len]usize = undefined;
        for (&order, 0..) |*slot, i| slot.* = i;
        if (sorted) {
            const Sort = struct {
                fn less(_: void, a: usize, b: usize) bool {
                    return std.mem.lessThan(u8, jsonName(T, fields[a].name), jsonName(T, fields[b].name));
                }
            };
            std.mem.sort(usize, &order, {}, Sort.less);
        }
        const final = order;
        break :blk &final;
    };
}

/// Whether two Zig values hold the same data: slices by what is in them,
/// pointers by what they point at. For leaving out fields at their default.
pub fn deepEql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    if (T == Value) return a.eql(b);
    if (comptime isArrayList(T)) return deepEql(a.items, b.items);
    if (comptime mapKind(T) != null) return a.count() == 0 and b.count() == 0;
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.fields) |f| if (!deepEql(@field(a, f.name), @field(b, f.name))) return false;
            return true;
        },
        .@"union" => |info| {
            if (info.tag_type == null) return false;
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            switch (a) {
                inline else => |payload, tag| return deepEql(payload, @field(b, @tagName(tag))),
            }
        },
        .array => {
            for (a, b) |x, y| if (!deepEql(x, y)) return false;
            return true;
        },
        .vector => |info| {
            const x: [info.len]info.child = a;
            const y: [info.len]info.child = b;
            return deepEql(x, y);
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                if (a.len != b.len) return false;
                for (a, b) |x, y| if (!deepEql(x, y)) return false;
                return true;
            },
            .one => return a == b or deepEql(a.*, b.*),
            else => return a == b,
        },
        .optional => {
            if (a == null or b == null) return a == null and b == null;
            return deepEql(a.?, b.?);
        },
        else => return a == b,
    }
}

/// Refuse, at compile time, declarations that name fields a type does not
/// have: a misspelt rename would otherwise do nothing, silently.
pub fn check(comptime T: type) void {
    comptime {
        if (@hasDecl(T, "json_rename")) {
            for (std.meta.fieldNames(@TypeOf(T.json_rename))) |name| if (!hasMember(T, name))
                @compileError("fluxion-json: " ++ @typeName(T) ++ ".json_rename names ." ++ name ++ ", which " ++ @typeName(T) ++ " does not have");
        }
        if (@hasDecl(T, "json_ignore")) {
            for (T.json_ignore) |ignored| if (!hasMember(T, @tagName(ignored)))
                @compileError("fluxion-json: " ++ @typeName(T) ++ ".json_ignore names ." ++ @tagName(ignored) ++ ", which " ++ @typeName(T) ++ " does not have");
        }
        if (@hasDecl(T, "json_tag") and @typeInfo(T) != .@"union")
            @compileError("fluxion-json: json_tag is for unions, and " ++ @typeName(T) ++ " is not one");
    }
}

fn hasMember(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasField(T, name),
        else => false,
    };
}

fn convertCase(comptime name: []const u8, comptime case: Case) []const u8 {
    return comptime blk: {
        var out: [name.len]u8 = undefined;
        var len = 0;
        var upper = case == .pascal;
        for (name) |c| {
            if (c == '_' and len > 0) {
                if (case == .kebab) {
                    out[len] = '-';
                    len += 1;
                } else upper = true;
                continue;
            }
            out[len] = if (upper) std.ascii.toUpper(c) else c;
            upper = false;
            len += 1;
        }
        const final = out[0..len].*;
        break :blk &final;
    };
}

test "names follow the case and the renames a type declares" {
    const Accessor = struct {
        buffer_view: u32,
        byte_offset: u32,
        kind: u8,
        _private: u8,

        pub const json_case = .camel;
        pub const json_rename = .{ .kind = "type" };
    };
    try testing.expectEqualStrings("bufferView", jsonName(Accessor, "buffer_view"));
    try testing.expectEqualStrings("type", jsonName(Accessor, "kind"));
    try testing.expectEqualStrings("_private", jsonName(Accessor, "_private"));
    try testing.expectEqualStrings("ByteOffset", comptime convertCase("byte_offset", .pascal));
    try testing.expectEqualStrings("byte-offset", comptime convertCase("byte_offset", .kebab));
}

test "sorted order is by the name a field is written as" {
    const T = struct {
        zebra: u8,
        apple: u8,
        middle: u8,

        pub const json_rename = .{ .zebra = "aardvark" };
    };
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, fieldOrder(T, false));
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, fieldOrder(T, true));
    const U = struct { b: u8, c: u8, a: u8 };
    try testing.expectEqualSlices(usize, &.{ 2, 0, 1 }, fieldOrder(U, true));
}

test "the standard containers are recognised" {
    try testing.expect(isArrayList(std.ArrayList(u8)));
    try testing.expect(isArrayList(std.array_list.Managed(u8)));
    try testing.expect(!isArrayList(struct { items: []u8, capacity: usize, other: u8 }));
    try testing.expectEqual(MapKind.unordered, mapKind(std.StringHashMap(u8)).?);
    try testing.expectEqual(MapKind.unordered, mapKind(std.StringHashMapUnmanaged(u8)).?);
    try testing.expectEqual(MapKind.ordered, mapKind(std.StringArrayHashMapUnmanaged(u8)).?);
    try testing.expectEqual(@as(?MapKind, null), mapKind(std.AutoHashMap(u32, u8)));
}

test "deepEql looks through slices and pointers" {
    const T = struct { name: []const u8, tags: []const []const u8, next: ?*const u8 };
    const one: u8 = 1;
    const also_one: u8 = 1;
    const a: T = .{ .name = "x", .tags = &.{ "a", "b" }, .next = &one };
    const b: T = .{ .name = "x", .tags = &.{ "a", "b" }, .next = &also_one };
    try testing.expect(deepEql(a, b));
    try testing.expect(!deepEql(a, T{ .name = "x", .tags = &.{"a"}, .next = &one }));
    try testing.expect(!deepEql(a, T{ .name = "x", .tags = &.{ "a", "b" }, .next = null }));
}
