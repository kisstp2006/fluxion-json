// SPDX-License-Identifier: CC0-1.0

//! Reading and writing timed against `std.json`, on three documents shaped
//! like what a game keeps in JSON: a tile map (numbers), a list of records
//! (strings and small objects) and a string table (one very wide object).
//!
//!   zig build bench
//!
//! Each case runs both libraries in turn, several rounds, and keeps the best
//! time of each: on a busy machine the spread between runs is larger than
//! most differences worth measuring.

const std = @import("std");
const json = @import("fluxion_json");

const Map = struct {
    width: u32,
    height: u32,
    tilewidth: u32,
    layers: []const Layer,
    objects: []const MapObject,

    const Layer = struct { name: []const u8, data: []const u32, opacity: f32, visible: bool };
    const MapObject = struct {
        id: u32,
        name: []const u8,
        x: f32,
        y: f32,
        properties: struct { hp: i32, team: []const u8 },
    };
};

const Record = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
    tags: []const []const u8,
    active: bool,
    score: f64,
    address: struct { city: []const u8, zip: []const u8 },
    bio: []const u8,
};

const rounds = 7;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout.interface;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const map = try makeMap(arena.allocator(), random);
    const records = try makeRecords(arena.allocator(), random);
    const strings = try makeStrings(arena.allocator(), random);

    const map_text = try json.stringify(arena.allocator(), map, .{});
    const records_text = try json.stringify(arena.allocator(), records, .{});
    const strings_text = try json.stringify(arena.allocator(), strings, .{});

    try out.print("{s:<34} {s:>12} {s:>12} {s:>8}\n", .{ "", "fluxion-json", "std.json", "ratio" });
    try compare(out, io, "tile map: parse to a tree", map_text.len, parseTree, parseStdTree, .{ gpa, map_text });
    try compare(out, io, "tile map: parse into structs", map_text.len, parseTyped, parseStdTyped, .{ gpa, Map, map_text });
    try compare(out, io, "tile map: write compact", map_text.len, writeOurs, writeStd, .{ gpa, map, false });
    try compare(out, io, "tile map: write indented", map_text.len, writeOurs, writeStd, .{ gpa, map, true });
    try compare(out, io, "records: parse to a tree", records_text.len, parseTree, parseStdTree, .{ gpa, records_text });
    try compare(out, io, "records: parse into structs", records_text.len, parseTyped, parseStdTyped, .{ gpa, []const Record, records_text });
    try compare(out, io, "records: write compact", records_text.len, writeOurs, writeStd, .{ gpa, records, false });
    try compare(out, io, "records: write indented", records_text.len, writeOurs, writeStd, .{ gpa, records, true });
    try compare(out, io, "string table: parse to a tree", strings_text.len, parseTree, parseStdTree, .{ gpa, strings_text });
    try compare(out, io, "string table: look up every key", strings_text.len, lookupOurs, lookupStd, .{ gpa, strings_text });
    try out.print("\nsizes: tile map {d} bytes, records {d}, string table {d}\n", .{ map_text.len, records_text.len, strings_text.len });
    try out.flush();
}

fn compare(
    out: *std.Io.Writer,
    io: std.Io,
    label: []const u8,
    bytes: usize,
    comptime ours: anytype,
    comptime theirs: anytype,
    args: anytype,
) !void {
    var best_ours: u64 = std.math.maxInt(u64);
    var best_theirs: u64 = std.math.maxInt(u64);
    for (0..rounds) |_| {
        best_ours = @min(best_ours, try time(io, ours, args));
        best_theirs = @min(best_theirs, try time(io, theirs, args));
    }
    const mb = @as(f64, @floatFromInt(bytes)) / (1024 * 1024);
    const ours_rate = mb / (@as(f64, @floatFromInt(best_ours)) / std.time.ns_per_s);
    const theirs_rate = mb / (@as(f64, @floatFromInt(best_theirs)) / std.time.ns_per_s);
    try out.print("{s:<34} {d:>7.0} MB/s {d:>7.0} MB/s {d:>7.2}x\n", .{ label, ours_rate, theirs_rate, ours_rate / theirs_rate });
    try out.flush();
}

fn time(io: std.Io, comptime f: anytype, args: anytype) !u64 {
    const start = std.Io.Timestamp.now(io, .awake);
    try @call(.auto, f, args);
    const elapsed = start.durationTo(std.Io.Timestamp.now(io, .awake));
    return @intCast(elapsed.nanoseconds);
}

fn parseTree(gpa: std.mem.Allocator, text: []const u8) !void {
    const doc = try json.parse(gpa, text, .{});
    doc.deinit();
}

fn parseStdTree(gpa: std.mem.Allocator, text: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    parsed.deinit();
}

fn parseTyped(gpa: std.mem.Allocator, comptime T: type, text: []const u8) !void {
    const parsed = try json.parseAs(T, gpa, text, .{});
    parsed.deinit();
}

fn parseStdTyped(gpa: std.mem.Allocator, comptime T: type, text: []const u8) !void {
    const parsed = try std.json.parseFromSlice(T, gpa, text, .{});
    parsed.deinit();
}

fn writeOurs(gpa: std.mem.Allocator, value: anytype, indented: bool) !void {
    const text = try json.stringify(gpa, value, .{ .indent = if (indented) 2 else 0 });
    gpa.free(text);
}

fn writeStd(gpa: std.mem.Allocator, value: anytype, indented: bool) !void {
    const text = try std.json.Stringify.valueAlloc(gpa, value, .{ .whitespace = if (indented) .indent_2 else .minified });
    gpa.free(text);
}

fn lookupOurs(gpa: std.mem.Allocator, text: []const u8) !void {
    const doc = try json.parse(gpa, text, .{});
    defer doc.deinit();
    var found: usize = 0;
    for (doc.root.keys()) |key| found += @intFromBool(doc.root.get(key) != .null);
    if (found != doc.root.len()) return error.Lost;
}

fn lookupStd(gpa: std.mem.Allocator, text: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    var found: usize = 0;
    for (parsed.value.object.keys()) |key| found += @intFromBool(parsed.value.object.get(key) != null);
    if (found != parsed.value.object.count()) return error.Lost;
}

fn makeMap(arena: std.mem.Allocator, random: std.Random) !Map {
    const size = 256;
    const layers = try arena.alloc(Map.Layer, 4);
    for (layers, 0..) |*layer, i| {
        const data = try arena.alloc(u32, size * size);
        for (data) |*tile| tile.* = if (random.uintLessThan(u8, 4) == 0) random.uintLessThan(u32, 400) else 0;
        layer.* = .{ .name = try std.fmt.allocPrint(arena, "layer {d}", .{i}), .data = data, .opacity = 1, .visible = i != 3 };
    }
    const objects = try arena.alloc(Map.MapObject, 2000);
    for (objects, 0..) |*object, i| object.* = .{
        .id = @intCast(i),
        .name = try std.fmt.allocPrint(arena, "spawn_{d}", .{i}),
        .x = random.float(f32) * 4096,
        .y = random.float(f32) * 4096,
        .properties = .{ .hp = random.intRangeAtMost(i32, 1, 500), .team = if (random.boolean()) "red" else "blue" },
    };
    return .{ .width = size, .height = size, .tilewidth = 16, .layers = layers, .objects = objects };
}

fn makeRecords(arena: std.mem.Allocator, random: std.Random) ![]const Record {
    const cities = [_][]const u8{ "Budapest", "Szeged", "Debrecen", "Zürich", "東京", "São Paulo" };
    const records = try arena.alloc(Record, 20_000);
    for (records, 0..) |*record, i| record.* = .{
        .id = @intCast(i),
        .name = try std.fmt.allocPrint(arena, "Player {d}", .{i}),
        .email = try std.fmt.allocPrint(arena, "player{d}@example.com", .{i}),
        .tags = if (random.boolean()) &.{ "mage", "healer" } else &.{"rogue"},
        .active = random.boolean(),
        .score = @round(random.float(f64) * 100_000) / 100,
        .address = .{ .city = cities[random.uintLessThan(usize, cities.len)], .zip = try std.fmt.allocPrint(arena, "{d:0>5}", .{random.uintLessThan(u32, 99999)}) },
        .bio = "Likes \"quoted\" things,\nnew lines, and café au lait.",
    };
    return records;
}

fn makeStrings(arena: std.mem.Allocator, random: std.Random) !std.StringArrayHashMapUnmanaged([]const u8) {
    var table: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    const words = [_][]const u8{ "Start", "the", "game", "Options", "Quit", "Continue", "Load", "Save", "Volume", "Inventory" };
    for (0..20_000) |i| {
        const key = try std.fmt.allocPrint(arena, "ui.screen{d}.label{d}", .{ i / 50, i % 50 });
        const value = try std.fmt.allocPrint(arena, "{s} {s} {s}", .{
            words[random.uintLessThan(usize, words.len)],
            words[random.uintLessThan(usize, words.len)],
            words[random.uintLessThan(usize, words.len)],
        });
        try table.put(arena, key, value);
    }
    return table;
}
