// SPDX-License-Identifier: CC0-1.0

const std = @import("std");
const testing = std.testing;

const Writer = @import("Writer.zig");
const Number = @import("number.zig").Number;
const reflect = @import("reflect.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Object = value_mod.Object;
const Array = value_mod.Array;
const Document = @import("Document.zig");

/// Write any value JSON can hold. The mapping, which `decode` reads back:
///
///   bool, integers, floats      true/false, numbers (NaN and infinity: see `non_finite`)
///   ?T                          null, or the T
///   enum, enum literal          the member's name as a string
///   []const u8, string literals a string, as is any null-terminated u8 pointer
///   slices, arrays, vectors     an array; `[N]u8` and `&[_]u8{...}` too, for colours and hashes
///   tuples                      an array
///   structs                     an object, fields in declaration order
///   tagged unions               {"arm": payload}, or "arm" when it has none
///   std.ArrayList               an array of its items
///   string-keyed std maps       an object
///   Value, *Object, *Array      as they are
pub fn write(w: *Writer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    if (T == Value) return writeValue(w, value);
    if (T == *Object or T == *const Object) return writeObject(w, value);
    if (T == *Array or T == *const Array) return writeItems(w, value.items());
    if (T == Number) return w.writeNumber(value);
    if (T == Document or T == *Document or T == *const Document) return writeValue(w, value.root);
    if (comptime isParsed(T)) return write(w, value.value);
    if (comptime reflect.hasHook(T, "toJson")) return value.toJson(w);
    switch (@typeInfo(T)) {
        .null => return w.writeNull(),
        .bool => return w.writeBool(value),
        .int => return w.writeInt(value),
        .comptime_int => return w.writeInt(@as(std.math.IntFittingRange(value, value), value)),
        .float => return w.writeFloat(value),
        .comptime_float => return w.writeFloat(@as(f64, value)),
        .enum_literal => return w.writeString(@tagName(value)),
        .optional => return if (value) |payload| write(w, payload) else w.writeNull(),
        .@"enum" => return writeEnum(w, value),
        .@"union" => return writeUnion(w, value),
        .@"struct" => return writeStruct(w, value),
        .array => |info| {
            if (info.child == u8 and info.sentinel() != null) return w.writeString(std.mem.sliceTo(&value, 0));
            return writeItems(w, &value);
        },
        .vector => |info| {
            const items: [info.len]info.child = value;
            return writeItems(w, &items);
        },
        .pointer => |info| switch (info.size) {
            .one => switch (@typeInfo(info.child)) {
                .array => |array| {
                    if (array.child == u8 and array.sentinel() != null) return w.writeString(std.mem.sliceTo(value, 0));
                    return writeItems(w, value);
                },
                else => return write(w, value.*),
            },
            .slice => return if (info.child == u8) w.writeString(value) else writeItems(w, value),
            .many => {
                if (info.child != u8 or info.sentinel() == null) cannot(T);
                return w.writeString(std.mem.span(value));
            },
            .c => cannot(T),
        },
        else => cannot(T),
    }
}

fn cannot(comptime T: type) noreturn {
    @compileError("fluxion-json cannot write a " ++ @typeName(T) ++ " as JSON");
}

/// A `Parsed(T)`, handed over where its `.value` was meant.
fn isParsed(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or !@hasField(T, "value") or !@hasField(T, "arena")) return false;
    return T == @import("decode.zig").Parsed(@FieldType(T, "value"));
}

fn writeValue(w: *Writer, v: Value) Writer.Error!void {
    switch (v) {
        .null => try w.writeNull(),
        .bool => |b| try w.writeBool(b),
        .int => |i| try w.writeInt(i),
        .float => |f| try w.writeFloat(f),
        .string => |s| try w.writeString(s),
        .array => |a| try writeItems(w, a.items()),
        .object => |o| try writeObject(w, o),
    }
}

fn writeObject(w: *Writer, object: *const Object) Writer.Error!void {
    try w.beginObject();
    const keys = object.keys();
    const values = object.values();
    if (!w.options.sort_keys or keys.len < 2) {
        for (keys, values) |k, v| try w.field(k, v);
    } else {
        const gpa = object.arena.child_allocator;
        const order = try gpa.alloc(u32, keys.len);
        defer gpa.free(order);
        for (order, 0..) |*slot, i| slot.* = @intCast(i);
        std.mem.sortUnstable(u32, order, keys, struct {
            fn less(names: []const []const u8, a: u32, b: u32) bool {
                return std.mem.lessThan(u8, names[a], names[b]);
            }
        }.less);
        for (order) |i| try w.field(keys[i], values[i]);
    }
    try w.endObject();
}

fn writeItems(w: *Writer, items: anytype) Writer.Error!void {
    try w.beginArray();
    for (items) |item| try write(w, item);
    try w.endArray();
}

fn writeEnum(w: *Writer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T).@"enum";
    if (info.is_exhaustive) switch (value) {
        inline else => |tag| return w.writeString(comptime reflect.jsonName(T, @tagName(tag))),
    };
    inline for (info.fields) |f| {
        if (@intFromEnum(value) == f.value) return w.writeString(comptime reflect.jsonName(T, f.name));
    }
    return w.writeInt(@intFromEnum(value));
}

fn writeUnion(w: *Writer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    if (@typeInfo(T).@"union".tag_type == null)
        @compileError("fluxion-json cannot write the untagged union " ++ @typeName(T) ++ ": nothing says which field is in use");
    switch (value) {
        inline else => |payload, tag| {
            const name = comptime reflect.jsonName(T, @tagName(tag));
            const Payload = @TypeOf(payload);
            if (comptime reflect.tagKey(T)) |tag_key| {
                if (Payload != void and (@typeInfo(Payload) != .@"struct" or @typeInfo(Payload).@"struct".is_tuple))
                    @compileError("fluxion-json: " ++ @typeName(T) ++ " has a json_tag, so ." ++ @tagName(tag) ++ " must hold a struct or nothing, not " ++ @typeName(Payload));
                try w.beginObject();
                try w.field(tag_key, name);
                if (Payload != void) try writeMembers(w, payload);
                return w.endObject();
            }
            if (Payload == void) return w.writeString(name);
            try w.beginObject();
            try w.field(name, payload);
            return w.endObject();
        },
    }
}

fn writeStruct(w: *Writer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T).@"struct";
    if (info.is_tuple) {
        try w.beginArray();
        inline for (info.fields) |f| try write(w, @field(value, f.name));
        return w.endArray();
    }
    if (comptime reflect.isArrayList(T)) return writeItems(w, value.items);
    if (comptime reflect.mapKind(T)) |kind| return writeMap(w, value, kind);
    try w.beginObject();
    try writeMembers(w, value);
    try w.endObject();
}

fn writeMembers(w: *Writer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    const fields = @typeInfo(T).@"struct".fields;
    if (fields.len == 0) return;
    const order = if (w.options.sort_keys) reflect.fieldOrder(T, true) else reflect.fieldOrder(T, false);
    for (order) |index| switch (index) {
        inline 0...fields.len - 1 => |i| try writeMember(w, value, fields[i]),
        else => unreachable,
    };
}

fn writeMember(w: *Writer, value: anytype, comptime f: std.builtin.Type.StructField) Writer.Error!void {
    const T = @TypeOf(value);
    if (f.type == void or comptime reflect.isIgnored(T, f.name)) return;
    const member = @field(value, f.name);
    if (@typeInfo(f.type) == .optional and w.options.skip_nulls and member == null) return;
    if (!f.is_comptime and w.options.skip_defaults) {
        if (comptime f.defaultValue()) |default| {
            if (reflect.deepEql(member, default)) return;
        }
    }
    try w.field(comptime reflect.jsonName(T, f.name), member);
}

fn writeMap(w: *Writer, map: anytype, comptime kind: reflect.MapKind) Writer.Error!void {
    try w.beginObject();
    if (kind == .ordered and !w.options.sort_keys) {
        for (map.keys(), map.values()) |k, v| try w.field(k, v);
    } else try writeSorted(w, map);
    try w.endObject();
}

/// A map's members in key order, found a batch at a time - the smallest
/// keys not yet written, kept in a small heap - so no memory is needed
/// however large the map is.
fn writeSorted(w: *Writer, map: anytype) Writer.Error!void {
    const V = reflect.MapValue(@TypeOf(map));
    const Entry = struct { key: []const u8, value: *const V };
    const Heap = struct {
        fn larger(a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, b.key, a.key);
        }

        fn up(heap: []Entry, start: usize) void {
            var i = start;
            while (i > 0) {
                const parent = (i - 1) / 2;
                if (!larger(heap[i], heap[parent])) break;
                std.mem.swap(Entry, &heap[i], &heap[parent]);
                i = parent;
            }
        }

        fn down(heap: []Entry) void {
            var i: usize = 0;
            while (true) {
                var top = i;
                for ([_]usize{ 2 * i + 1, 2 * i + 2 }) |child| {
                    if (child < heap.len and larger(heap[child], heap[top])) top = child;
                }
                if (top == i) return;
                std.mem.swap(Entry, &heap[i], &heap[top]);
                i = top;
            }
        }

        fn ascending(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    };

    var batch: [64]Entry = undefined;
    var after: ?[]const u8 = null;
    while (true) {
        var count: usize = 0;
        var it = map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (after) |last| if (!std.mem.lessThan(u8, last, key)) continue;
            const candidate: Entry = .{ .key = key, .value = entry.value_ptr };
            if (count < batch.len) {
                batch[count] = candidate;
                count += 1;
                Heap.up(batch[0..count], count - 1);
            } else if (std.mem.lessThan(u8, key, batch[0].key)) {
                batch[0] = candidate;
                Heap.down(&batch);
            }
        }
        std.mem.sortUnstable(Entry, batch[0..count], {}, Heap.ascending);
        for (batch[0..count]) |entry| try w.field(entry.key, entry.value.*);
        if (count < batch.len) return;
        after = batch[count - 1].key;
    }
}

fn expectJson(expected: []const u8, value: anytype, options: Writer.Options) !void {
    var buf: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var writer: Writer = .init(&out, options);
    try write(&writer, value);
    try testing.expectEqualStrings(expected, out.buffered());
}

test "scalars and anonymous literals" {
    try expectJson("null", null, .{});
    try expectJson("true", true, .{});
    try expectJson("-12", -12, .{});
    try expectJson("2.5", 2.5, .{});
    try expectJson("\"hello\"", "hello", .{});
    try expectJson("\"red\"", .red, .{});
    try expectJson("[1,\"two\",3.0]", .{ 1, "two", @as(f32, 3) }, .{});
    try expectJson("{\"name\":\"Ada\",\"level\":3,\"pos\":[1.5,2]}", .{ .name = "Ada", .level = 3, .pos = .{ 1.5, 2 } }, .{});
    try expectJson("[]", .{}, .{});
}

test "structs, optionals, enums and tagged unions" {
    const Shape = union(enum) {
        circle: struct { radius: f32 },
        point,
    };
    const Enemy = struct {
        kind: enum { goblin, troll } = .goblin,
        hp: u16 = 10,
        name: ?[]const u8 = null,
        shape: Shape = .point,
        scale: @Vector(2, f32) = .{ 1, 1 },
        tint: [3]u8 = .{ 255, 255, 255 },
        cache: u32 = 0,
        nothing: void = {},

        pub const json_ignore = .{.cache};
    };
    try expectJson(
        \\{"kind":"troll","hp":40,"name":null,"shape":{"circle":{"radius":2.5}},"scale":[1.0,1.0],"tint":[255,255,255]}
    , Enemy{ .kind = .troll, .hp = 40, .shape = .{ .circle = .{ .radius = 2.5 } } }, .{});
    try expectJson(
        \\{"kind":"troll","hp":40,"shape":{"circle":{"radius":2.5}}}
    , Enemy{ .kind = .troll, .hp = 40, .shape = .{ .circle = .{ .radius = 2.5 } } }, .{ .skip_defaults = true });
    try expectJson(
        \\{"kind":"goblin","hp":10,"shape":"point","scale":[1.0,1.0],"tint":[255,255,255]}
    , Enemy{}, .{ .skip_nulls = true });
}

test "a union with a json_tag writes its tag inside the payload" {
    const Event = union(enum) {
        spawn: struct { x: i32, y: i32 },
        quit,

        pub const json_tag = "type";
    };
    try expectJson("[{\"type\":\"spawn\",\"x\":1,\"y\":2},{\"type\":\"quit\"}]", [_]Event{ .{ .spawn = .{ .x = 1, .y = 2 } }, .quit }, .{});
}

test "names follow json_case and json_rename" {
    const Accessor = struct {
        buffer_view: u32,
        component_type: u32,
        kind: enum { scalar, vec3 },

        pub const json_case = .camel;
        pub const json_rename = .{ .kind = "type" };
    };
    try expectJson("{\"bufferView\":0,\"componentType\":5126,\"type\":\"vec3\"}", Accessor{ .buffer_view = 0, .component_type = 5126, .kind = .vec3 }, .{});
}

test "sort_keys orders struct fields and object members alike" {
    const T = struct { b: u8 = 2, a: u8 = 1, c: struct { z: u8 = 0, y: u8 = 0 } = .{} };
    try expectJson("{\"a\":1,\"b\":2,\"c\":{\"y\":0,\"z\":0}}", T{}, .{ .sort_keys = true });
}

test "the standard containers" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, &.{ 1, 2, 3 });
    try expectJson("[1,2,3]", list, .{});

    var ordered: std.StringArrayHashMapUnmanaged(u8) = .empty;
    defer ordered.deinit(testing.allocator);
    try ordered.put(testing.allocator, "zeta", 1);
    try ordered.put(testing.allocator, "alpha", 2);
    try expectJson("{\"zeta\":1,\"alpha\":2}", ordered, .{});
    try expectJson("{\"alpha\":2,\"zeta\":1}", ordered, .{ .sort_keys = true });

    var unordered: std.StringHashMap(u32) = .init(testing.allocator);
    defer unordered.deinit();
    var names: [200][8]u8 = undefined;
    for (&names, 0..) |*name, i| {
        _ = std.fmt.bufPrint(name, "key{d:0>5}", .{199 - i}) catch unreachable;
        try unordered.put(name, @intCast(199 - i));
    }
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer: Writer = .init(&out.writer, .{});
    try write(&writer, unordered);
    var expected: std.Io.Writer.Allocating = .init(testing.allocator);
    defer expected.deinit();
    try expected.writer.writeByte('{');
    for (0..200) |i| try expected.writer.print("{s}\"key{d:0>5}\":{d}", .{ if (i == 0) "" else ",", i, i });
    try expected.writer.writeByte('}');
    try testing.expectEqualStrings(expected.written(), out.written());
}

test "a type can write itself" {
    const Color = struct {
        r: u8,
        g: u8,
        b: u8,

        pub fn toJson(c: @This(), w: *Writer) Writer.Error!void {
            var buf: [7]u8 = undefined;
            try w.writeString(std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }) catch unreachable);
        }
    };
    try expectJson("{\"sky\":\"#87ceeb\"}", .{ .sky = Color{ .r = 0x87, .g = 0xce, .b = 0xeb } }, .{});
}

test "a document or a parsed value is written as what it holds" {
    const doc = try @import("root.zig").parse(testing.allocator, "{\"a\": [1, 2]}", .{});
    defer doc.deinit();
    try expectJson("{\"a\":[1,2]}", doc, .{});
    try expectJson("{\"a\":[1,2]}", &doc, .{});
    const parsed = try @import("decode.zig").parseAs(struct { a: []const u8 }, testing.allocator, "{\"a\": \"b\"}", .{});
    defer parsed.deinit();
    try expectJson("{\"a\":\"b\"}", parsed, .{});
}

test "strings in their various Zig forms, and bytes that are not strings" {
    const literal: [*:0]const u8 = "c string";
    const buffer: [8:0]u8 = "fixed\x00\x00\x00".*;
    try expectJson("[\"slice\",\"c string\",\"fixed\",\"literal\"]", .{ @as([]const u8, "slice"), literal, buffer, "literal" }, .{});
    const rgba = [_]u8{ 255, 128, 0, 255 };
    try expectJson("[[255,128,0,255],[255,128,0,255],[1,2]]", .{ rgba, &rgba, &[_]u8{ 1, 2 } }, .{});
}
