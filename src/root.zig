// SPDX-License-Identifier: CC0-1.0

//! Fluxion JSON - read, write, load and save JSON: straight into Zig types,
//! or as a tree to walk and change.
//!
//! ```zig
//! const json = @import("fluxion_json");
//!
//! // Into a struct. Missing fields take their defaults, unknown ones are passed over.
//! const config = try json.parseAs(Config, gpa, text, .{});
//! defer config.deinit();
//!
//! // Or as a tree, like JSON.parse. Whatever is missing reads as null.
//! const doc = try json.parse(gpa, text, .{});
//! defer doc.deinit();
//! const hp = doc.root.get("player").get("hp").asInt(i32) orelse 100;
//!
//! // And back out, like JSON.stringify.
//! const out = try json.stringify(gpa, config.value, .{ .indent = 2 });
//! defer gpa.free(out);
//!
//! // The same values as CBOR, which every read above takes as well.
//! const bytes = try json.stringify(gpa, config.value, .{ .format = .cbor });
//! defer gpa.free(bytes);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const value_mod = @import("value.zig");
const decode = @import("decode.zig");
const reflect = @import("reflect.zig");

pub const Value = value_mod.Value;
pub const Array = value_mod.Array;
pub const Object = value_mod.Object;
pub const Document = @import("Document.zig");
pub const Reader = @import("Reader.zig");
pub const Writer = @import("Writer.zig");
pub const Diagnostics = @import("Diagnostics.zig");
pub const Number = @import("number.zig").Number;
pub const Parsed = decode.Parsed;

pub const ParseOptions = decode.Options;
pub const WriteOptions = Writer.Options;
pub const Syntax = Reader.Syntax;
pub const Format = Reader.Format;
pub const DuplicateKeys = value_mod.DuplicateKeys;
pub const UnknownFields = decode.UnknownFields;
pub const NonFinite = Writer.NonFinite;
pub const Case = reflect.Case;

pub const Error = decode.Error;
pub const EditError = value_mod.EditError;
pub const StringifyError = error{ OutOfMemory, TooDeep, NonFiniteNumber };
pub const LoadError = Error || Io.Dir.ReadFileAllocError;
pub const SaveError = StringifyError || Io.Dir.CreateFileAtomicError || Io.File.Writer.Error || Io.File.Atomic.ReplaceError;

/// Read JSON text into a tree, as `JSON.parse` does - or CBOR, told apart by
/// its self-described tag. The text can be freed as soon as this returns: the
/// document holds copies of what it needs.
pub fn parse(gpa: Allocator, text: []const u8, options: ParseOptions) Error!Document {
    if (options.diagnostics) |d| d.* = .{};
    return parseDocument(gpa, text, options);
}

/// Read JSON text straight into a `T`. A struct field missing from the text
/// takes its default, or null if it is optional; a member the struct has no
/// field for is passed over. See `stringify` for how each Zig type is
/// spelt in JSON.
pub fn parseAs(comptime T: type, gpa: Allocator, text: []const u8, options: ParseOptions) Error!Parsed(T) {
    if (options.diagnostics) |d| d.* = .{};
    return decode.parseAs(T, gpa, text, options);
}

/// Write any value as JSON text, as `JSON.stringify` does - or, with
/// `.format = .cbor`, as CBOR bytes. The caller frees the result.
///
///   bool, integers, floats        true and false, numbers; floats in the fewest digits that read back the same
///   ?T                            null, or the T
///   enums                         the member's name
///   []const u8, string literals   strings
///   slices, arrays, tuples        arrays, `[N]u8` included
///   structs                       objects, in the order the fields are declared
///   tagged unions                 {"arm": payload}, or just "arm" when there is no payload
///   std.ArrayList                 an array
///   string-keyed std maps         objects
///   Value, Document.root          as they are
///
/// A type can change its own spelling with `json_case`, `json_rename`,
/// `json_ignore`, `json_tag`, or a `toJson` function: see the README.
pub fn stringify(gpa: Allocator, value: anytype, options: WriteOptions) StringifyError![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var writer: Writer = .init(&out.writer, options);
    writer.write(value) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        error.OutOfMemory, error.TooDeep, error.NonFiniteNumber => |e| e,
    };
    return out.toOwnedSlice();
}

/// Write any value as JSON text into `out`. Remember to flush `out`.
pub fn write(out: *Io.Writer, value: anytype, options: WriteOptions) Writer.Error!void {
    var writer: Writer = .init(out, options);
    return writer.write(value);
}

/// Format any value as JSON inside `print`: `std.debug.print("{f}\n", .{json.fmt(x, .{ .indent = 2 })})`.
pub fn fmt(value: anytype, options: WriteOptions) Formatter(@TypeOf(value)) {
    return .{ .value = value, .options = options };
}

pub fn Formatter(comptime T: type) type {
    return struct {
        value: T,
        options: WriteOptions,

        pub fn format(f: @This(), w: *Io.Writer) Io.Writer.Error!void {
            var writer: Writer = .init(w, f.options);
            writer.write(f.value) catch return error.WriteFailed;
        }
    };
}

/// Whether `text` is one JSON value and nothing else, in the syntax the
/// options name - or one CBOR item JSON can hold. Allocates nothing.
pub fn valid(text: []const u8, options: ParseOptions) bool {
    var frames: Reader.CborFrames = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(std.mem.asBytes(&frames));
    var reader: Reader = .init(fixed.allocator(), text, .{ .syntax = options.syntax, .format = options.format, .max_depth = options.max_depth });
    defer reader.deinit();
    reader.skipValue() catch return false;
    return (reader.next() catch return false) == null;
}

/// Lay JSON text out again - indented, compact, ASCII-only - without building
/// a tree. Keys stay in their order and numbers keep their digits; comments
/// go, and JSON5 comes out as JSON. With a `format` on either side it turns
/// JSON into CBOR and back. The caller frees the result.
pub fn reformat(gpa: Allocator, text: []const u8, parse_options: ParseOptions, options: WriteOptions) (Error || StringifyError)![]u8 {
    if (parse_options.diagnostics) |d| d.* = .{};
    var reader: Reader = .init(gpa, text, decode.readerOptions(parse_options));
    defer reader.deinit();
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var writer: Writer = .init(&out.writer, options);
    while (try reader.next()) |token| {
        const written = switch (token) {
            .object_begin => writer.beginObject(),
            .object_end => writer.endObject(),
            .array_begin => writer.beginArray(),
            .array_end => writer.endArray(),
            .key => |name| writer.key(name),
            .string => |s| writer.writeString(s),
            .number => |n| writer.writeNumber(n),
            .bool => |b| writer.writeBool(b),
            .null => writer.writeNull(),
        };
        written catch |err| return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            error.OutOfMemory, error.TooDeep, error.NonFiniteNumber => |e| e,
        };
    }
    return out.toOwnedSlice();
}

/// Read a JSON or CBOR file into a tree. `path` is relative to the working
/// directory. Diagnostics name the file, so messages read
/// `settings.json:3:14: ...`.
pub fn load(gpa: Allocator, io: Io, path: []const u8, options: ParseOptions) LoadError!Document {
    const text = try readFile(gpa, io, path, options);
    defer gpa.free(text);
    return parseDocument(gpa, text, options);
}

/// Read a JSON file straight into a `T`. See `parseAs` and `load`.
pub fn loadAs(comptime T: type, gpa: Allocator, io: Io, path: []const u8, options: ParseOptions) LoadError!Parsed(T) {
    const text = try readFile(gpa, io, path, options);
    defer gpa.free(text);
    return decode.parseAs(T, gpa, text, options);
}

/// Write any value to a JSON file ending with a line break, or with
/// `.format = .cbor` to a CBOR file. The file is written beside the old one
/// and then put in its place, so a crash halfway through leaves the old file
/// whole rather than half a new one. Directories on the way to `path` are
/// made if they are missing.
pub fn save(io: Io, path: []const u8, value: anytype, options: WriteOptions) SaveError!void {
    var file = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .make_path = true });
    defer file.deinit(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = file.file.writer(io, &buffer);
    var writer: Writer = .init(&file_writer.interface, options);
    writer.write(value) catch |err| return switch (err) {
        error.WriteFailed => file_writer.err.?,
        error.OutOfMemory, error.TooDeep, error.NonFiniteNumber => |e| e,
    };
    if (options.format == .json) file_writer.interface.writeByte('\n') catch return file_writer.err.?;
    try file_writer.flush();
    try file.replace(io);
}

fn parseDocument(gpa: Allocator, text: []const u8, options: ParseOptions) Error!Document {
    var doc: Document = try .init(gpa);
    errdefer doc.deinit();
    var reader: Reader = .init(gpa, text, decode.readerOptions(options));
    defer reader.deinit();
    doc.root = try value_mod.readValue(&reader, doc.arena, options.duplicate_keys);
    _ = try reader.next();
    return doc;
}

fn readFile(gpa: Allocator, io: Io, path: []const u8, options: ParseOptions) Io.Dir.ReadFileAllocError![]u8 {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.setFile(path);
    }
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| {
        if (options.diagnostics) |d| d.setMessage("cannot read the file: {s}", .{@errorName(err)});
        return err;
    };
}

test {
    _ = @import("number.zig");
    _ = @import("utf8.zig");
    _ = @import("cbor.zig");
    _ = Diagnostics;
    _ = Reader;
    _ = Writer;
    _ = value_mod;
    _ = Document;
    _ = @import("encode.zig");
    _ = decode;
    _ = reflect;
    _ = @import("conformance_test.zig");
}

test "every name this file exports is one that exists" {
    testing.refAllDecls(@This());
}

const Config = struct {
    title: []const u8 = "Untitled",
    window: struct { width: u32 = 1280, height: u32 = 720, fullscreen: bool = false } = .{},
    volume: f32 = 0.8,
    difficulty: enum { easy, normal, hard } = .normal,
    bindings: []const Binding = &.{},

    const Binding = struct { action: []const u8, key: []const u8 };
};

test "the pieces compose: text to a struct, to a tree, and back" {
    const text =
        \\{
        \\  "title": "Fluxion",
        \\  "window": { "width": 1920, "fullscreen": true },
        \\  "difficulty": "hard",
        \\  "bindings": [{ "action": "jump", "key": "space" }]
        \\}
    ;
    const config = try parseAs(Config, testing.allocator, text, .{});
    defer config.deinit();
    try testing.expectEqual(@as(u32, 1920), config.value.window.width);
    try testing.expectEqual(@as(u32, 720), config.value.window.height);
    try testing.expectEqualStrings("space", config.value.bindings[0].key);

    const written = try stringify(testing.allocator, config.value, .{ .indent = 2 });
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(
        \\{
        \\  "title": "Fluxion",
        \\  "window": { "width": 1920, "height": 720, "fullscreen": true },
        \\  "volume": 0.8,
        \\  "difficulty": "hard",
        \\  "bindings": [{ "action": "jump", "key": "space" }]
        \\}
    , written);

    var doc = try parse(testing.allocator, written, .{});
    defer doc.deinit();
    try doc.root.get("window").put("height", 1080);
    try doc.root.get("bindings").append(.{ .action = "fire", .key = "mouse1" });
    const again = try doc.root.parseAs(Config, testing.allocator, .{});
    defer again.deinit();
    try testing.expectEqual(@as(u32, 1080), again.value.window.height);
    try testing.expectEqualStrings("fire", again.value.bindings[1].action);
}

test "settings over defaults, written back with only what changed" {
    var settings = try parse(testing.allocator,
        \\{"audio": {"volume": 0.8, "music": true}, "video": {"vsync": true}}
    , .{});
    defer settings.deinit();
    var user = try parse(testing.allocator,
        \\// the player's own file
        \\{"audio": {"music": false,},}
    , .{ .syntax = .jsonc });
    defer user.deinit();
    try settings.merge(user.root);
    const merged = try stringify(testing.allocator, settings.root, .{});
    defer testing.allocator.free(merged);
    try testing.expectEqualStrings("{\"audio\":{\"volume\":0.8,\"music\":false},\"video\":{\"vsync\":true}}", merged);

    const Audio = struct { volume: f32 = 0.8, music: bool = true };
    const changed = try stringify(testing.allocator, Audio{ .music = false }, .{ .skip_defaults = true });
    defer testing.allocator.free(changed);
    try testing.expectEqualStrings("{\"music\":false}", changed);
}

test "fmt prints a value inside a format string" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.print("config: {f}", .{fmt(.{ .a = 1, .b = .{ true, null } }, .{})});
    try testing.expectEqualStrings("config: {\"a\":1,\"b\":[true,null]}", w.buffered());

    var doc = try parse(testing.allocator, "[1, \"x\"]", .{});
    defer doc.deinit();
    w = .fixed(&buf);
    try w.print("{f}", .{doc.root});
    try testing.expectEqualStrings("[1,\"x\"]", w.buffered());
}

test "valid says whether text is JSON, in the syntax asked about" {
    try testing.expect(valid("{\"a\": [1, 2.5, \"x\\n\", true, null]}", .{}));
    try testing.expect(!valid("{\"a\": 1,}", .{}));
    try testing.expect(valid("{\"a\": 1,}", .{ .syntax = .jsonc }));
    try testing.expect(!valid("[1] [2]", .{}));
    try testing.expect(!valid("", .{}));
    try testing.expect(valid("{a: 'b'}", .{ .syntax = .json5 }));
}

test "reformat lays text out again without a tree" {
    const pretty = try reformat(testing.allocator,
        \\{a: 0x10, /* note */ "list": [1.50, 'two',], nested: {"deep": [[]]}}
    , .{ .syntax = .json5 }, .{ .indent = 2, .line_width = 40 });
    defer testing.allocator.free(pretty);
    try testing.expectEqualStrings(
        \\{
        \\  "a": 16,
        \\  "list": [1.50, "two"],
        \\  "nested": { "deep": [[]] }
        \\}
    , pretty);
}

test "a file saved and loaded again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/saves/slot1.json", .{tmp.sub_path});

    try save(testing.io, path, Config{ .title = "saved" }, .{ .indent = 2 });
    const loaded = try loadAs(Config, testing.allocator, testing.io, path, .{});
    defer loaded.deinit();
    try testing.expectEqualStrings("saved", loaded.value.title);

    var doc = try load(testing.allocator, testing.io, path, .{});
    defer doc.deinit();
    try testing.expectEqual(@as(?u32, 1280), doc.root.at("/window/width").asInt(u32));

    var diagnostics: Diagnostics = .{};
    try testing.expectError(error.FileNotFound, load(testing.allocator, testing.io, "no/such/file.json", .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("cannot read the file: FileNotFound", diagnostics.message());
}

test "typed values come back from CBOR exactly as they went in" {
    const Sample = struct {
        f32_tenth: f32 = 0.1,
        f64_tenth: f64 = 0.1,
        f64_from_f32: f64 = @as(f32, 0.1),
        half_max: f64 = 65504.0,
        big: u64 = std.math.maxInt(u64),
        small: i64 = std.math.minInt(i64),
        name: []const u8 = "Ada ✓",
        config: Config = .{ .title = "cbor", .bindings = &.{.{ .action = "jump", .key = "space" }} },
    };
    const bytes = try stringify(testing.allocator, Sample{}, .{ .format = .cbor });
    defer testing.allocator.free(bytes);
    const back = try parseAs(Sample, testing.allocator, bytes, .{});
    defer back.deinit();
    try testing.expectEqualDeep(Sample{}, back.value);

    const text = try stringify(testing.allocator, Sample{}, .{});
    defer testing.allocator.free(text);
    const from_text = try parseAs(Sample, testing.allocator, text, .{});
    defer from_text.deinit();
    try testing.expectEqualDeep(from_text.value, back.value);
}

test "a CBOR file saved and loaded again, and one that is broken" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/saves/slot1.cbor", .{tmp.sub_path});

    try save(testing.io, path, Config{ .title = "saved" }, .{ .format = .cbor });
    const bytes = try Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.startsWith(u8, bytes, "\xD9\xD9\xF7"));
    try testing.expect(bytes[bytes.len - 1] != '\n');

    const loaded = try loadAs(Config, testing.allocator, testing.io, path, .{});
    defer loaded.deinit();
    try testing.expectEqualStrings("saved", loaded.value.title);
    const doc = try load(testing.allocator, testing.io, path, .{});
    defer doc.deinit();
    try testing.expectEqual(@as(?u32, 1280), doc.root.at("/window/width").asInt(u32));

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "broken.cbor", .data = "\xD9\xD9\xF7\xA1\x61\x61" });
    var broken_buf: [128]u8 = undefined;
    const broken = try std.fmt.bufPrint(&broken_buf, ".zig-cache/tmp/{s}/broken.cbor", .{tmp.sub_path});
    var diagnostics: Diagnostics = .{};
    try testing.expectError(error.SyntaxError, load(testing.allocator, testing.io, broken, .{ .diagnostics = &diagnostics }));
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.print("{f}", .{diagnostics});
    var expected_buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}: byte 6: the CBOR ends before the map opened at byte 3 is closed", .{broken});
    try testing.expectEqualStrings(expected, w.buffered());
}

test "diagnostics from a file name it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "broken.json", .data = "{\n  \"volume\": 0.8\n  \"muted\": true\n}\n" });
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/broken.json", .{tmp.sub_path});

    var diagnostics: Diagnostics = .{};
    try testing.expectError(error.SyntaxError, load(testing.allocator, testing.io, path, .{ .diagnostics = &diagnostics }));
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.print("{f}", .{diagnostics});
    var expected_buf: [512]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf,
        \\{s}:3:3: expected ',' or '}}' after an object member, found '"'
        \\      "muted": true
        \\      ^
    , .{path});
    try testing.expectEqualStrings(expected, w.buffered());
}
