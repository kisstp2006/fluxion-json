// SPDX-License-Identifier: CC0-1.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;

const Reader = @import("Reader.zig");
const Token = Reader.Token;
const Diagnostics = @import("Diagnostics.zig");
const Number = @import("number.zig").Number;
const reflect = @import("reflect.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;

pub const Options = struct {
    /// Strict JSON, or JSON with comments, or all of JSON5.
    syntax: Reader.Syntax = .json,
    /// JSON text or CBOR. Null tells them apart by the CBOR self-described
    /// tag, which `stringify` and `save` write at the start of CBOR; CBOR
    /// from elsewhere, without one, has to be named.
    format: ?Reader.Format = null,
    /// Nesting deeper than this is refused with `error.TooDeep`.
    max_depth: u16 = 512,
    duplicate_keys: value_mod.DuplicateKeys = .last,
    /// What to do with a member no field of the struct is named for.
    unknown_fields: UnknownFields = .ignore,
    /// Filled in when reading fails: where, and why.
    diagnostics: ?*Diagnostics = null,
};

pub const UnknownFields = enum {
    /// Pass over it, so a file from a newer version of a program still reads.
    ignore,
    /// Refuse it with `error.UnknownField`, and say which field it was
    /// probably meant to be.
    fail,
};

/// Everything reading can fail with. `Diagnostics` has the details.
pub const Error = error{
    /// The text is not JSON, or not the kind of JSON the options allow.
    SyntaxError,
    /// Nested deeper than `max_depth`.
    TooDeep,
    /// A key appears twice in one object and `duplicate_keys` is `.fail`.
    DuplicateKey,
    OutOfMemory,
    /// A value of the wrong kind: a string where a number belongs.
    WrongType,
    /// A number that does not fit the field: 300 for a `u8`.
    OutOfRange,
    /// An array of the wrong length for a fixed-size array or tuple.
    LengthMismatch,
    /// A struct field with no default and no value in the object.
    MissingField,
    /// A member the struct has no field for, with `unknown_fields = .fail`.
    UnknownField,
    /// A string naming no member of an enum, or no arm of a union.
    UnknownTag,
};

/// A value read from JSON and the memory it points into. `deinit` frees it
/// all at once.
pub fn Parsed(comptime T: type) type {
    return struct {
        value: T,
        arena: *ArenaAllocator,

        pub fn deinit(self: @This()) void {
            const gpa = self.arena.child_allocator;
            self.arena.deinit();
            gpa.destroy(self.arena);
        }
    };
}

pub fn parseAs(comptime T: type, gpa: Allocator, text: []const u8, options: Options) Error!Parsed(T) {
    var reader: Reader = .init(gpa, text, readerOptions(options));
    defer reader.deinit();
    return parseFrom(T, gpa, &reader, options);
}

pub fn parseValueAs(comptime T: type, gpa: Allocator, value: Value, options: Options) Error!Parsed(T) {
    var reader: Reader = .initValue(gpa, value, readerOptions(options));
    defer reader.deinit();
    return parseFrom(T, gpa, &reader, options);
}

pub fn readerOptions(options: Options) Reader.Options {
    return .{ .syntax = options.syntax, .format = options.format, .max_depth = options.max_depth, .diagnostics = options.diagnostics };
}

fn parseFrom(comptime T: type, gpa: Allocator, reader: *Reader, options: Options) Error!Parsed(T) {
    const arena = try gpa.create(ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    var context: Context = .{ .reader = reader, .arena = arena, .options = options };
    const value = try context.decode(T, null);
    _ = try reader.next();
    return .{ .value = value, .arena = arena };
}

/// One step of the way from the document's root to a value, for saying
/// where a problem is.
const Path = struct {
    parent: ?*const Path,
    step: union(enum) { key: []const u8, index: usize },
};

const Context = struct {
    reader: *Reader,
    arena: *ArenaAllocator,
    options: Options,

    fn memory(c: *Context) Allocator {
        return c.arena.allocator();
    }

    fn gpa(c: *Context) Allocator {
        return c.arena.child_allocator;
    }

    fn decode(c: *Context, comptime T: type, path: ?*const Path) Error!T {
        if (T == Value) return c.readTree();
        if (T == @import("Document.zig"))
            @compileError("fluxion-json: a Document is read with json.parse; parseAs reads into your own types, or into json.Value");
        if (comptime reflect.hasHook(T, "fromJson")) {
            const tree = try c.readTree();
            return T.fromJson(tree, c.memory()) catch |err| {
                c.report(path, "{s}.fromJson refused this value: {s}", .{ comptime shortName(T), @errorName(err) });
                return err;
            };
        }
        switch (@typeInfo(T)) {
            .bool => {
                const token = try c.next();
                if (token == .bool) return token.bool;
                return c.wrongType(token, "true or false", path);
            },
            .int => {
                const token = try c.next();
                if (token != .number) return c.wrongType(token, "a whole number", path);
                return c.integer(T, token.number, path);
            },
            .float => {
                const token = try c.next();
                if (token != .number) return c.wrongType(token, "a number", path);
                const f = token.number.asFloat(T);
                if (std.math.isInf(f) and std.mem.indexOf(u8, token.number.text, "Infinity") == null)
                    return c.fail(error.OutOfRange, path, "{s} is too large for {s}", .{ token.number.text, @typeName(T) });
                return f;
            },
            .optional => |info| {
                if (try c.peek() == .null) {
                    _ = try c.next();
                    return null;
                }
                return try c.decode(info.child, path);
            },
            .@"enum" => return c.decodeEnum(T, path),
            .@"union" => return c.decodeUnion(T, path),
            .@"struct" => |info| {
                if (info.is_tuple) return c.decodeTuple(T, path);
                if (comptime reflect.isArrayList(T)) return c.decodeArrayList(T, path);
                if (comptime reflect.mapKind(T) != null) return c.decodeMap(T, path);
                return c.decodeFields(T, path, false, null);
            },
            .array => return c.decodeArray(T, path),
            .vector => |info| return try c.decodeArray([info.len]info.child, path),
            .pointer => |info| switch (info.size) {
                .slice => return c.decodeSlice(T, path),
                .one => {
                    const target = try c.memory().create(info.child);
                    target.* = try c.decode(info.child, path);
                    return target;
                },
                else => @compileError("fluxion-json cannot read a " ++ @typeName(T) ++ ": it does not say how many items"),
            },
            else => @compileError("fluxion-json cannot read a " ++ @typeName(T)),
        }
    }

    fn next(c: *Context) Error!Token {
        return (try c.reader.next()) orelse error.SyntaxError;
    }

    fn peek(c: *Context) Error!Reader.Kind {
        return (try c.reader.peek()) orelse error.SyntaxError;
    }

    fn readTree(c: *Context) Error!Value {
        return value_mod.readValue(c.reader, c.arena, c.options.duplicate_keys);
    }

    fn integer(c: *Context, comptime T: type, n: Number, path: ?*const Path) Error!T {
        if (n.asInt(T)) |i| return i;
        const f = n.asFloat(f64);
        if (!n.isInteger() and (!std.math.isFinite(f) or @floor(f) != f))
            return c.fail(error.WrongType, path, "expected a whole number, found {s}", .{n.text});
        return c.fail(error.OutOfRange, path, "{s} does not fit in a {s}, which holds {d} to {d}", .{
            n.text, @typeName(T), std.math.minInt(T), std.math.maxInt(T),
        });
    }

    fn decodeEnum(c: *Context, comptime T: type, path: ?*const Path) Error!T {
        const token = try c.next();
        switch (token) {
            .string => |s| {
                const names = comptime enumNames(T);
                return names.get(s) orelse c.unknownTag(T, s, path);
            },
            .number => |n| {
                if (n.asInt(@typeInfo(T).@"enum".tag_type)) |i| {
                    if (std.enums.fromInt(T, i)) |member| return member;
                }
                return c.fail(error.UnknownTag, path, "{s} is not the number of any value this field can take", .{n.text});
            },
            else => return c.wrongType(token, "a string", path),
        }
    }

    fn decodeUnion(c: *Context, comptime T: type, path: ?*const Path) Error!T {
        const info = @typeInfo(T).@"union";
        if (info.tag_type == null)
            @compileError("fluxion-json cannot read the untagged union " ++ @typeName(T) ++ ": nothing would say which field is in use");
        if (comptime reflect.tagKey(T)) |tag_key| return c.decodeTaggedUnion(T, tag_key, path);
        const token = try c.next();
        switch (token) {
            .string => |s| {
                inline for (info.fields) |f| {
                    if (std.mem.eql(u8, s, comptime reflect.jsonName(T, f.name))) {
                        if (f.type == void) return @unionInit(T, f.name, {});
                        return c.fail(error.WrongType, path, "\"{s}\" holds a value, so it is written {{\"{s}\": ...}}", .{ s, s });
                    }
                }
                return c.unknownTag(T, s, path);
            },
            .object_begin => {
                const inner = try c.next();
                if (inner != .key) return c.fail(error.WrongType, path, "expected an object with one member, found an empty one", .{});
                inline for (info.fields) |f| {
                    const name = comptime reflect.jsonName(T, f.name);
                    if (std.mem.eql(u8, inner.key, name)) {
                        const step: Path = .{ .parent = path, .step = .{ .key = name } };
                        const payload: f.type = if (f.type == void) try c.reader.skipValue() else try c.decode(f.type, &step);
                        if (try c.next() != .object_end)
                            return c.fail(error.WrongType, path, "a union is written as an object with exactly one member", .{});
                        return @unionInit(T, f.name, payload);
                    }
                }
                return c.unknownTag(T, inner.key, path);
            },
            else => return c.wrongType(token, "an object with one member, or a string", path),
        }
    }

    /// A union whose arm is named by a member inside the payload's object:
    /// `{"type": "circle", "radius": 2}`. The tag is usually first, and is
    /// read as it streams by; when it is not, the object is read whole first.
    fn decodeTaggedUnion(c: *Context, comptime T: type, comptime tag_key: []const u8, path: ?*const Path) Error!T {
        const token = try c.next();
        if (token != .object_begin) return c.wrongType(token, "an object", path);
        const start = c.reader.token_start;
        const first = try c.next();
        if (first == .key and std.mem.eql(u8, first.key, tag_key)) {
            const tag_step: Path = .{ .parent = path, .step = .{ .key = tag_key } };
            const tag = try c.next();
            if (tag != .string) return c.wrongType(tag, "a string naming one of the union's arms", &tag_step);
            inline for (@typeInfo(T).@"union".fields) |f| {
                if (std.mem.eql(u8, tag.string, comptime reflect.jsonName(T, f.name))) {
                    const Payload = if (f.type == void) struct {} else f.type;
                    const payload = try c.decodeFields(Payload, path, true, tag_key);
                    return @unionInit(T, f.name, if (f.type == void) {} else payload);
                }
            }
            return c.unknownTag(T, tag.string, &tag_step);
        }
        if (first == .object_end) return c.failAt(error.MissingField, start, path, "missing the \"{s}\" member that says which kind this is", .{tag_key});

        var builder: value_mod.Builder = .{
            .arena = c.arena,
            .duplicates = c.options.duplicate_keys,
            .diagnostics = c.options.diagnostics,
            .source = c.reader.input,
        };
        defer builder.deinit();
        try builder.begin(true, start);
        try builder.key(first.key);
        const tree = try value_mod.feed(&builder, c.reader);
        const tag = tree.get(tag_key);
        if (tag == .null) return c.failAt(error.MissingField, start, path, "missing the \"{s}\" member that says which kind this is", .{tag_key});
        if (tag != .string) return c.failAt(error.WrongType, start, path, "\"{s}\" should be a string naming one of the union's arms", .{tag_key});

        var reader: Reader = .initValue(c.gpa(), tree, .{ .max_depth = c.options.max_depth, .diagnostics = c.options.diagnostics });
        defer reader.deinit();
        var inner: Context = .{ .reader = &reader, .arena = c.arena, .options = c.options };
        inline for (@typeInfo(T).@"union".fields) |f| {
            if (std.mem.eql(u8, tag.string, comptime reflect.jsonName(T, f.name))) {
                const Payload = if (f.type == void) struct {} else f.type;
                const payload = try inner.decodeFields(Payload, path, false, tag_key);
                return @unionInit(T, f.name, if (f.type == void) {} else payload);
            }
        }
        return c.unknownTag(T, tag.string, path);
    }

    /// An object into the fields of `T`. `open` says the `{` has been read
    /// already; `skip_key` names a member that is not a field, a union's tag.
    fn decodeFields(c: *Context, comptime T: type, path: ?*const Path, open: bool, comptime skip_key: ?[]const u8) Error!T {
        if (@typeInfo(T) != .@"struct" or @typeInfo(T).@"struct".is_tuple)
            @compileError("fluxion-json: a union with a json_tag holds structs, and " ++ @typeName(T) ++ " is not one");
        const fields = @typeInfo(T).@"struct".fields;
        if (!open) {
            const token = try c.next();
            if (token != .object_begin) return c.wrongType(token, "an object", path);
        }
        const start = c.reader.token_start;
        const names = comptime fieldNames(T);
        var result: T = undefined;
        var seen: [fields.len]bool = @splat(false);
        while (true) {
            const key = switch (try c.next()) {
                .key => |name| name,
                .object_end => break,
                else => unreachable,
            };
            if (skip_key) |skipped| if (std.mem.eql(u8, key, skipped)) {
                try c.reader.skipValue();
                continue;
            };
            const index = names.get(key) orelse {
                if (c.options.unknown_fields == .fail) return c.unknownField(T, key, path);
                try c.reader.skipValue();
                continue;
            };
            inline for (fields, 0..) |f, i| {
                // What `fieldNames` leaves out is never read, so it is never
                // compiled as something to read either: a field in
                // `json_ignore` may be of a type JSON has no word for.
                if (comptime f.is_comptime or f.type == void or reflect.isIgnored(T, f.name)) continue;
                if (i == index) {
                    const name = comptime reflect.jsonName(T, f.name);
                    const keep_first = seen[i] and switch (c.options.duplicate_keys) {
                        .last => false,
                        .first => true,
                        .fail => return c.fail(error.DuplicateKey, path, "the field \"{s}\" is given twice", .{name}),
                    };
                    if (keep_first) {
                        try c.reader.skipValue();
                    } else {
                        const step: Path = .{ .parent = path, .step = .{ .key = name } };
                        @field(result, f.name) = try c.decode(f.type, &step);
                        seen[i] = true;
                    }
                }
            }
        }
        inline for (fields, 0..) |f, i| {
            if (!seen[i] and !f.is_comptime) {
                if (comptime f.defaultValue()) |default| {
                    @field(result, f.name) = default;
                } else if (@typeInfo(f.type) == .optional) {
                    @field(result, f.name) = null;
                } else if (f.type == void) {
                    @field(result, f.name) = {};
                } else {
                    return c.failAt(error.MissingField, start, path, "missing the field \"{s}\", which has no default", .{comptime reflect.jsonName(T, f.name)});
                }
            }
        }
        return result;
    }

    fn decodeTuple(c: *Context, comptime T: type, path: ?*const Path) Error!T {
        const fields = @typeInfo(T).@"struct".fields;
        const token = try c.next();
        if (token != .array_begin) return c.wrongType(token, "an array", path);
        var result: T = undefined;
        inline for (fields, 0..) |f, i| {
            if (try c.peek() == .array_end)
                return c.fail(error.LengthMismatch, path, "expected {d} items, found {d}", .{ fields.len, i });
            const step: Path = .{ .parent = path, .step = .{ .index = i } };
            @field(result, f.name) = try c.decode(f.type, &step);
        }
        if (try c.peek() != .array_end)
            return c.fail(error.LengthMismatch, path, "expected {d} items, found more", .{fields.len});
        _ = try c.next();
        return result;
    }

    fn decodeArray(c: *Context, comptime T: type, path: ?*const Path) Error!T {
        const info = @typeInfo(T).array;
        const token = try c.next();
        var result: T = undefined;
        if (info.child == u8 and token == .string) {
            const text = token.string;
            if (info.sentinel() != null) {
                if (text.len > info.len) return c.fail(error.LengthMismatch, path, "expected at most {d} bytes of text, found {d}", .{ info.len, text.len });
                result = std.mem.zeroes(T);
                @memcpy(result[0..text.len], text);
                return result;
            }
            if (text.len != info.len) return c.fail(error.LengthMismatch, path, "expected {d} bytes of text, found {d}", .{ info.len, text.len });
            @memcpy(&result, text);
            return result;
        }
        if (token != .array_begin) return c.wrongType(token, "an array", path);
        var count: usize = 0;
        while (try c.peek() != .array_end) : (count += 1) {
            if (count == info.len) return c.fail(error.LengthMismatch, path, "expected {d} items, found more", .{info.len});
            const step: Path = .{ .parent = path, .step = .{ .index = count } };
            result[count] = try c.decode(info.child, &step);
        }
        _ = try c.next();
        if (count != info.len) return c.fail(error.LengthMismatch, path, "expected {d} items, found {d}", .{ info.len, count });
        return result;
    }

    fn decodeSlice(c: *Context, comptime T: type, path: ?*const Path) Error!T {
        const info = @typeInfo(T).pointer;
        const token = try c.next();
        if (info.child == u8) {
            if (token != .string) return c.wrongType(token, "a string", path);
            if (info.sentinel() != null) return try c.memory().dupeZ(u8, token.string);
            return try c.memory().dupe(u8, token.string);
        }
        if (token != .array_begin) return c.wrongType(token, "an array", path);
        var items: std.ArrayListUnmanaged(info.child) = .empty;
        defer items.deinit(c.gpa());
        while (try c.peek() != .array_end) {
            const step: Path = .{ .parent = path, .step = .{ .index = items.items.len } };
            try items.append(c.gpa(), try c.decode(info.child, &step));
        }
        _ = try c.next();
        if (info.sentinel()) |end| {
            const copy = try c.memory().allocSentinel(info.child, items.items.len, end);
            @memcpy(copy, items.items);
            return copy;
        }
        return try c.memory().dupe(info.child, items.items);
    }

    fn decodeArrayList(c: *Context, comptime T: type, path: ?*const Path) Error!T {
        const items = try c.decodeSlice(@FieldType(T, "items"), path);
        if (@hasField(T, "allocator")) return .{ .items = items, .capacity = items.len, .allocator = c.memory() };
        return .{ .items = items, .capacity = items.len };
    }

    fn decodeMap(c: *Context, comptime T: type, path: ?*const Path) Error!T {
        const managed = @hasField(T, "allocator");
        const token = try c.next();
        if (token != .object_begin) return c.wrongType(token, "an object", path);
        var map: T = if (managed) .init(c.memory()) else .empty;
        while (true) {
            const key = switch (try c.next()) {
                .key => |name| try c.memory().dupe(u8, name),
                .object_end => break,
                else => unreachable,
            };
            const step: Path = .{ .parent = path, .step = .{ .key = key } };
            const item = try c.decode(reflect.MapValue(T), &step);
            const slot = if (managed) try map.getOrPut(key) else try map.getOrPut(c.memory(), key);
            if (slot.found_existing) switch (c.options.duplicate_keys) {
                .last => {},
                .first => continue,
                .fail => return c.fail(error.DuplicateKey, path, "the key \"{s}\" appears more than once in this object", .{key}),
            };
            slot.value_ptr.* = item;
        }
        return map;
    }

    fn wrongType(c: *Context, token: Token, comptime expected: []const u8, path: ?*const Path) Error {
        return c.fail(error.WrongType, path, "expected " ++ expected ++ ", found {f}", .{Found{ .token = token }});
    }

    fn unknownField(c: *Context, comptime T: type, key: []const u8, path: ?*const Path) Error {
        const known = comptime fieldList(T);
        if (closest(known, key)) |guess|
            return c.fail(error.UnknownField, path, "there is no field \"{s}\"; did you mean \"{s}\"?", .{ key, guess });
        return c.fail(error.UnknownField, path, "there is no field \"{s}\"", .{key});
    }

    fn unknownTag(c: *Context, comptime T: type, name: []const u8, path: ?*const Path) Error {
        const known = comptime tagList(T);
        if (closest(known, name)) |guess|
            return c.fail(error.UnknownTag, path, "\"{s}\" is not one of the values this can take; did you mean \"{s}\"?", .{ name, guess });
        if (known.len <= 8)
            return c.fail(error.UnknownTag, path, "\"{s}\" is not one of {s}", .{ name, comptime listed(known) });
        return c.fail(error.UnknownTag, path, "\"{s}\" is not one of the values this can take", .{name});
    }

    fn fail(c: *Context, err: Error, path: ?*const Path, comptime fmt: []const u8, args: anytype) Error {
        c.report(path, fmt, args);
        return err;
    }

    fn failAt(c: *Context, err: Error, offset: usize, path: ?*const Path, comptime fmt: []const u8, args: anytype) Error {
        c.reader.reportAt(offset, fmt, args);
        c.setPath(path);
        return err;
    }

    fn report(c: *Context, path: ?*const Path, comptime fmt: []const u8, args: anytype) void {
        c.reader.report(fmt, args);
        c.setPath(path);
    }

    fn setPath(c: *Context, path: ?*const Path) void {
        const d = c.options.diagnostics orelse return;
        var buf: [240]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        writePath(&w, path) catch {};
        d.setPath(w.buffered());
    }
};

fn writePath(w: *std.Io.Writer, path: ?*const Path) std.Io.Writer.Error!void {
    const p = path orelse return;
    try writePath(w, p.parent);
    try w.writeByte('/');
    switch (p.step) {
        .index => |i| try w.print("{d}", .{i}),
        .key => |key| for (key) |c| switch (c) {
            '~' => try w.writeAll("~0"),
            '/' => try w.writeAll("~1"),
            else => try w.writeByte(c),
        },
    }
}

const Found = struct {
    token: Token,

    pub fn format(f: Found, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (f.token) {
            .object_begin => try w.writeAll("an object"),
            .array_begin => try w.writeAll("an array"),
            .string => |s| {
                if (s.len <= 40) return w.print("the string \"{s}\"", .{s});
                var cut: usize = 37;
                while (cut > 0 and s[cut] & 0xC0 == 0x80) cut -= 1;
                try w.print("the string \"{s}...\"", .{s[0..cut]});
            },
            .number => |n| try w.print("the number {s}", .{n.text}),
            .bool => |b| try w.writeAll(if (b) "true" else "false"),
            .null => try w.writeAll("null"),
            .key, .object_end, .array_end => try w.writeAll("the end of the object"),
        }
    }
};

fn fieldNames(comptime T: type) std.StaticStringMap(usize) {
    return comptime blk: {
        const fields = @typeInfo(T).@"struct".fields;
        var entries: [fields.len]struct { []const u8, usize } = undefined;
        var count = 0;
        for (fields, 0..) |f, i| {
            if (f.is_comptime or f.type == void) continue;
            if (reflect.isIgnored(T, f.name)) {
                if (f.defaultValue() == null and @typeInfo(f.type) != .optional)
                    @compileError("fluxion-json: " ++ @typeName(T) ++ "." ++ f.name ++ " is in json_ignore, so it needs a default to be read with");
                continue;
            }
            entries[count] = .{ reflect.jsonName(T, f.name), i };
            count += 1;
        }
        break :blk .initComptime(entries[0..count]);
    };
}

fn fieldList(comptime T: type) []const []const u8 {
    return comptime blk: {
        var names: []const []const u8 = &.{};
        for (@typeInfo(T).@"struct".fields) |f| {
            if (f.is_comptime or f.type == void or reflect.isIgnored(T, f.name)) continue;
            names = names ++ &[_][]const u8{reflect.jsonName(T, f.name)};
        }
        break :blk names;
    };
}

/// A type's own name, without the file and namespaces it is declared in.
fn shortName(comptime T: type) []const u8 {
    const full = @typeName(T);
    return full[if (std.mem.lastIndexOfScalar(u8, full, '.')) |dot| dot + 1 else 0..];
}

fn enumNames(comptime T: type) std.StaticStringMap(T) {
    return comptime blk: {
        const fields = @typeInfo(T).@"enum".fields;
        var entries: [fields.len]struct { []const u8, T } = undefined;
        for (fields, &entries) |f, *entry| entry.* = .{ reflect.jsonName(T, f.name), @field(T, f.name) };
        break :blk .initComptime(entries);
    };
}

fn tagList(comptime T: type) []const []const u8 {
    return comptime blk: {
        var names: []const []const u8 = &.{};
        for (std.meta.fieldNames(T)) |name| names = names ++ &[_][]const u8{reflect.jsonName(T, name)};
        break :blk names;
    };
}

fn listed(comptime names: []const []const u8) []const u8 {
    return comptime blk: {
        var text: []const u8 = "";
        for (names, 0..) |name, i| {
            const separator = if (i == 0) "" else if (i == names.len - 1) " or " else ", ";
            text = text ++ separator ++ "\"" ++ name ++ "\"";
        }
        break :blk text;
    };
}

/// The candidate `word` is most likely a misspelling of: within a third of
/// its length in edits, ignoring case.
fn closest(candidates: []const []const u8, word: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);
    for (candidates) |candidate| {
        const d = editDistance(word, candidate);
        if (d < best_distance) {
            best = candidate;
            best_distance = d;
        }
    }
    return if (best_distance <= @max(1, word.len / 3)) best else null;
}

fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 64 or b.len > 64) return std.math.maxInt(usize);
    var row: [65]usize = undefined;
    for (row[0 .. b.len + 1], 0..) |*cell, j| cell.* = j;
    for (a, 0..) |ca, i| {
        var diagonal = row[0];
        row[0] = i + 1;
        for (b, 0..) |cb, j| {
            const above = row[j + 1];
            const cost: usize = @intFromBool(std.ascii.toLower(ca) != std.ascii.toLower(cb));
            row[j + 1] = @min(above + 1, row[j] + 1, diagonal + cost);
            diagonal = above;
        }
    }
    return row[b.len];
}

const Settings = struct {
    title: []const u8 = "Untitled",
    width: u32 = 1280,
    height: u32 = 720,
    fullscreen: bool = false,
    volume: f32 = 0.8,
    difficulty: enum { easy, normal, hard } = .normal,
    keys: []const []const u8 = &.{},
    scale: ?f64 = null,
};

fn expectParsed(comptime T: type, text: []const u8, options: Options) !Parsed(T) {
    return parseAs(T, testing.allocator, text, options);
}

fn expectFailure(comptime T: type, text: []const u8, options: Options, expected: Error, message: []const u8, path: []const u8) !void {
    var diagnostics: Diagnostics = .{};
    var with = options;
    with.diagnostics = &diagnostics;
    try testing.expectError(expected, parseAs(T, testing.allocator, text, with));
    try testing.expectEqualStrings(message, diagnostics.message());
    try testing.expectEqualStrings(path, diagnostics.path());
}

test "a struct takes what the text has, and its defaults for the rest" {
    const parsed = try expectParsed(Settings,
        \\{"title": "Fluxion", "fullscreen": true, "difficulty": "hard", "keys": ["w", "a"], "extra": {"ignored": [1]}}
    , .{});
    defer parsed.deinit();
    const s = parsed.value;
    try testing.expectEqualStrings("Fluxion", s.title);
    try testing.expectEqual(@as(u32, 1280), s.width);
    try testing.expect(s.fullscreen);
    try testing.expectEqual(@as(f32, 0.8), s.volume);
    try testing.expectEqual(.hard, s.difficulty);
    try testing.expectEqualStrings("a", s.keys[1]);
    try testing.expectEqual(@as(?f64, null), s.scale);
}

test "the text can be freed as soon as it is read" {
    const text = try testing.allocator.dupe(u8, "{\"title\": \"copied\"}");
    const parsed = try expectParsed(Settings, text, .{});
    defer parsed.deinit();
    testing.allocator.free(text);
    try testing.expectEqualStrings("copied", parsed.value.title);
}

test "wrong values say what was expected, what was found, and where" {
    try expectFailure(Settings, "{\"width\": \"wide\"}", .{}, error.WrongType, "expected a whole number, found the string \"wide\"", "/width");
    try expectFailure(Settings, "{\"width\": -1}", .{}, error.OutOfRange, "-1 does not fit in a u32, which holds 0 to 4294967295", "/width");
    try expectFailure(Settings, "{\"width\": 1.5}", .{}, error.WrongType, "expected a whole number, found 1.5", "/width");
    try expectFailure(Settings, "{\"keys\": [\"w\", 3]}", .{}, error.WrongType, "expected a string, found the number 3", "/keys/1");
    try expectFailure(Settings, "{\"difficulty\": \"hardd\"}", .{}, error.UnknownTag, "\"hardd\" is not one of the values this can take; did you mean \"hard\"?", "/difficulty");
    try expectFailure(Settings, "{\"difficulty\": \"brutal\"}", .{}, error.UnknownTag, "\"brutal\" is not one of \"easy\", \"normal\" or \"hard\"", "/difficulty");
    try expectFailure(Settings, "{\"fulscreen\": true}", .{ .unknown_fields = .fail }, error.UnknownField, "there is no field \"fulscreen\"; did you mean \"fullscreen\"?", "");
    try expectFailure(Settings, "[1]", .{}, error.WrongType, "expected an object, found an array", "");
    try expectFailure(Settings, "{\"volume\": 1e39}", .{}, error.OutOfRange, "1e39 is too large for f32", "/volume");
    try expectFailure(struct { a: u8 }, "{}", .{}, error.MissingField, "missing the field \"a\", which has no default", "");
    try expectFailure(struct { a: u8 = 0 }, "{\"a\": 1, \"a\": 2}", .{ .duplicate_keys = .fail }, error.DuplicateKey, "the field \"a\" is given twice", "");
}

test "the place of a wrong value is its line and column" {
    var diagnostics: Diagnostics = .{};
    try testing.expectError(error.WrongType, parseAs(Settings, testing.allocator, "{\n  \"title\": \"x\",\n  \"height\": true\n}", .{ .diagnostics = &diagnostics }));
    try testing.expectEqual(@as(u32, 3), diagnostics.line);
    try testing.expectEqual(@as(u32, 13), diagnostics.column);
}

test "duplicate fields keep the last value unless told otherwise" {
    const T = struct { a: u8 = 0 };
    const last = try expectParsed(T, "{\"a\": 1, \"a\": 2}", .{});
    defer last.deinit();
    try testing.expectEqual(@as(u8, 2), last.value.a);
    const first = try expectParsed(T, "{\"a\": 1, \"a\": 2}", .{ .duplicate_keys = .first });
    defer first.deinit();
    try testing.expectEqual(@as(u8, 1), first.value.a);
}

test "unions, from either spelling" {
    const Shape = union(enum) {
        circle: struct { radius: f32 },
        rect: struct { w: f32, h: f32 },
        point,
    };
    const parsed = try expectParsed([]const Shape,
        \\[{"circle": {"radius": 2}}, "point", {"point": null}, {"rect": {"w": 1, "h": 2}}]
    , .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(f32, 2), parsed.value[0].circle.radius);
    try testing.expectEqual(Shape.point, parsed.value[1]);
    try testing.expectEqual(Shape.point, parsed.value[2]);
    try testing.expectEqual(@as(f32, 2), parsed.value[3].rect.h);
    try expectFailure(Shape, "\"circle\"", .{}, error.WrongType, "\"circle\" holds a value, so it is written {\"circle\": ...}", "");
    try expectFailure(Shape, "{\"square\": {}}", .{}, error.UnknownTag, "\"square\" is not one of \"circle\", \"rect\" or \"point\"", "");
}

test "a union with a json_tag finds its tag wherever it is" {
    const Event = union(enum) {
        spawn: struct { x: i32, y: i32 = 0 },
        quit,

        pub const json_tag = "type";
    };
    const parsed = try expectParsed([]const Event,
        \\[{"type": "spawn", "x": 3}, {"x": 4, "y": 5, "type": "spawn"}, {"type": "quit"}]
    , .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i32, 3), parsed.value[0].spawn.x);
    try testing.expectEqual(@as(i32, 5), parsed.value[1].spawn.y);
    try testing.expectEqual(Event.quit, parsed.value[2]);
    try expectFailure(Event, "{\"x\": 1}", .{}, error.MissingField, "missing the \"type\" member that says which kind this is", "");
    try expectFailure(Event, "{\"type\": \"spawn\", \"x\": \"far\"}", .{}, error.WrongType, "expected a whole number, found the string \"far\"", "/x");
}

test "arrays, tuples, vectors, pointers and fixed text" {
    const T = struct {
        rgba: [4]u8,
        pair: struct { []const u8, i32 },
        pos: @Vector(3, f32),
        id: [4]u8,
        name: [8:0]u8,
        next: ?*const u16,
        z: [:0]const u8,
    };
    const parsed = try expectParsed(T,
        \\{"rgba": [255, 0, 128, 255], "pair": ["one", 1], "pos": [1, 2, 3], "id": "abcd", "name": "Ada", "next": 7, "z": "zed"}
    , .{});
    defer parsed.deinit();
    const v = parsed.value;
    try testing.expectEqual([4]u8{ 255, 0, 128, 255 }, v.rgba);
    try testing.expectEqualStrings("one", v.pair[0]);
    try testing.expectEqual(@as(f32, 3), v.pos[2]);
    try testing.expectEqualStrings("abcd", &v.id);
    try testing.expectEqualStrings("Ada", std.mem.sliceTo(&v.name, 0));
    try testing.expectEqual(@as(u16, 7), v.next.?.*);
    try testing.expectEqualStrings("zed", v.z);
    try expectFailure([3]u8, "[1, 2]", .{}, error.LengthMismatch, "expected 3 items, found 2", "");
    try expectFailure(struct { u8, u8 }, "[1, 2, 3]", .{}, error.LengthMismatch, "expected 2 items, found more", "");
}

test "standard containers and Value fields" {
    const T = struct {
        list: std.ArrayList(u32),
        managed_list: std.array_list.Managed([]const u8),
        scores: std.StringHashMapUnmanaged(i32),
        managed_scores: std.StringHashMap(u8),
        order: std.StringArrayHashMapUnmanaged(bool),
        extra: Value,
    };
    const parsed = try expectParsed(T,
        \\{"list": [1, 2], "managed_list": ["a", "b"], "scores": {"ada": 3, "bob": -1}, "managed_scores": {"x": 9},
        \\ "order": {"z": true, "a": false}, "extra": {"any": ["thing", 1]}}
    , .{});
    defer parsed.deinit();
    const v = parsed.value;
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, v.list.items);
    try testing.expectEqualStrings("b", v.managed_list.items[1]);
    try testing.expectEqual(@as(i32, -1), v.scores.get("bob").?);
    try testing.expectEqual(@as(u8, 9), v.managed_scores.get("x").?);
    try testing.expectEqualStrings("z", v.order.keys()[0]);
    try testing.expectEqualStrings("thing", v.extra.get("any").get(0).asString().?);
}

test "a type can read itself from a Value" {
    const Color = struct {
        r: u8,
        g: u8,
        b: u8,

        pub fn fromJson(value: Value, _: Allocator) Error!@This() {
            const text = value.asString() orelse return error.WrongType;
            if (text.len != 7 or text[0] != '#') return error.WrongType;
            const n = std.fmt.parseInt(u24, text[1..], 16) catch return error.WrongType;
            return .{ .r = @truncate(n >> 16), .g = @truncate(n >> 8), .b = @truncate(n) };
        }
    };
    const parsed = try expectParsed(struct { sky: Color }, "{\"sky\": \"#87ceeb\"}", .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(u8, 0xce), parsed.value.sky.g);
    try expectFailure(struct { sky: Color }, "{\"sky\": 3}", .{}, error.WrongType, "Color.fromJson refused this value: WrongType", "/sky");
}

test "names follow json_case and json_rename when reading too" {
    const Accessor = struct {
        buffer_view: u32,
        kind: []const u8,
        cache: u32 = 99,

        pub const json_case = .camel;
        pub const json_rename = .{ .kind = "type" };
        pub const json_ignore = .{.cache};
    };
    const parsed = try expectParsed(Accessor, "{\"bufferView\": 2, \"type\": \"VEC3\", \"cache\": 5}", .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 2), parsed.value.buffer_view);
    try testing.expectEqualStrings("VEC3", parsed.value.kind);
    try testing.expectEqual(@as(u32, 99), parsed.value.cache);
}

test "a field in json_ignore may be of a type JSON has no word for" {
    // An allocator, say, kept beside what was read: nothing reads it, so
    // nothing has to know how.
    const Held = struct {
        name: []const u8 = "",
        gpa: ?std.mem.Allocator = null,

        pub const json_ignore = .{.gpa};
    };
    const parsed = try expectParsed(Held, "{\"name\": \"kept\", \"gpa\": 1}", .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("kept", parsed.value.name);
    try testing.expect(parsed.value.gpa == null);
}

test "a failed read gives back all its memory" {
    try testing.expectError(error.WrongType, parseAs(Settings, testing.allocator, "{\"title\": \"x\", \"keys\": [\"a\", \"b\", 3]}", .{}));
}

test "edit distance" {
    try testing.expectEqual(@as(usize, 1), editDistance("fulscreen", "fullscreen"));
    try testing.expectEqual(@as(usize, 0), editDistance("Width", "width"));
    try testing.expectEqual(@as(usize, 3), editDistance("kitten", "sitting"));
    try testing.expectEqual(@as(?[]const u8, null), closest(&.{ "alpha", "beta" }, "zzzzz"));
}
