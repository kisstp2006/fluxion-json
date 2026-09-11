// SPDX-License-Identifier: CC0-1.0

//! A tour of Fluxion JSON. Run it with `zig build example`.
//!
//! It reads JSON as a tree, reads it into a struct, builds and changes a
//! tree, lays it out, saves and loads a settings file with comments in it,
//! lays a player's settings over the defaults, and shows what a mistake in a
//! file looks like when it is reported.

const std = @import("std");
const json = @import("fluxion_json");

const Settings = struct {
    title: []const u8 = "Untitled",
    window: Window = .{},
    volume: f32 = 0.8,
    difficulty: enum { easy, normal, hard } = .normal,
    bindings: []const Binding = &.{},

    const Window = struct { width: u32 = 1280, height: u32 = 720, fullscreen: bool = false };
    const Binding = struct { action: []const u8, key: []const u8 };
};

const player_text =
    \\{
    \\  "name": "Ada",
    \\  "level": 7,
    \\  "position": { "x": 12.5, "y": -3 },
    \\  "inventory": [
    \\    { "item": "sword", "damage": 12 },
    \\    { "item": "potion", "count": 3 }
    \\  ]
    \\}
;

const settings_path = "zig-out/demo-settings.json";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout.interface;

    try out.print("--- read a tree, like JSON.parse ---\n", .{});
    const player = try json.parse(gpa, player_text, .{});
    defer player.deinit();
    const root = player.root;
    try out.print("{s} is level {d}, standing at x={d}\n", .{
        root.get("name").asString() orelse "nobody",
        root.get("level").asInt(u32) orelse 1,
        root.at("/position/x").asFloat(f32) orelse 0,
    });
    for (root.get("inventory").items()) |slot| {
        try out.print("  carries {s} x{d}\n", .{ slot.get("item").asString().?, slot.get("count").asInt(u32) orelse 1 });
    }
    // Nothing here has a "mana" member: every step reads as null, and the default wins.
    try out.print("mana: {d}\n\n", .{root.get("stats").get("mana").asInt(u32) orelse 100});

    try out.print("--- change it, and lay it out ---\n", .{});
    try root.put("level", 8);
    try root.get("inventory").append(.{ .item = "map", .marks = .{ 3, 14, 15, 92 } });
    try root.put("tiles", &[_]u8{ 0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55 });
    _ = root.remove("position");
    try out.print("{f}\n\n", .{json.fmt(root, .{ .indent = 2 })});

    try out.print("--- read straight into a struct ---\n", .{});
    const typed = try json.parseAs(Settings, gpa,
        \\{ "title": "Fluxion", "window": { "fullscreen": true }, "difficulty": "hard" }
    , .{});
    defer typed.deinit();
    const s = typed.value;
    try out.print("{s}: {d}x{d}, fullscreen {}, {t}, volume {d}\n\n", .{
        s.title, s.window.width, s.window.height, s.window.fullscreen, s.difficulty, s.volume,
    });

    try out.print("--- save a settings file, and load it back ---\n", .{});
    var settings = typed.value;
    settings.bindings = &.{ .{ .action = "jump", .key = "space" }, .{ .action = "fire", .key = "mouse1" } };
    try json.save(io, settings_path, settings, .{ .indent = 2, .skip_defaults = true });
    const saved = try std.Io.Dir.cwd().readFileAlloc(io, settings_path, gpa, .limited(1 << 16));
    defer gpa.free(saved);
    try out.print("{s}", .{saved});
    const loaded = try json.loadAs(Settings, gpa, io, settings_path, .{});
    defer loaded.deinit();
    try out.print("loaded back: {d} bindings, the second is {s}\n\n", .{ loaded.value.bindings.len, loaded.value.bindings[1].action });

    try out.print("--- a player's own settings over the defaults ---\n", .{});
    var merged = try json.parse(gpa, try json.stringify(init.arena.allocator(), Settings{}, .{}), .{});
    defer merged.deinit();
    const own = try json.parse(gpa,
        \\// Written by hand, so comments and a trailing comma are welcome here.
        \\{
        \\  "volume": 0.35,
        \\  "window": { "width": 2560, "height": 1440, },
        \\}
    , .{ .syntax = .jsonc });
    defer own.deinit();
    try merged.merge(own.root);
    try out.print("{f}\n\n", .{json.fmt(merged.root, .{ .indent = 2 })});

    try out.print("--- a mistake in a file ---\n", .{});
    var diagnostics: json.Diagnostics = .{};
    if (json.parseAs(Settings, gpa,
        \\{
        \\  "title": "Fluxion",
        \\  "window": { "width": "wide" }
        \\}
    , .{ .diagnostics = &diagnostics })) |unexpected| {
        unexpected.deinit();
    } else |err| {
        try out.print("{s}: {f}\n", .{ @errorName(err), diagnostics });
    }
    if (json.parse(gpa, "{ \"volume\": 0.8 \"muted\": true }", .{ .diagnostics = &diagnostics })) |unexpected| {
        unexpected.deinit();
    } else |err| {
        try out.print("{s}: {f}\n", .{ @errorName(err), diagnostics });
    }
    if (json.parseAs(Settings, gpa, "{ \"volumne\": 0.5 }", .{ .unknown_fields = .fail, .diagnostics = &diagnostics })) |unexpected| {
        unexpected.deinit();
    } else |err| {
        try out.print("{s}: {f}\n", .{ @errorName(err), diagnostics });
    }

    try out.flush();
}

test "settings survive a save and a load, and only what changed is written" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/settings.json", .{tmp.sub_path});

    const changed: Settings = .{ .volume = 0.5, .bindings = &.{.{ .action = "jump", .key = "space" }} };
    try json.save(std.testing.io, path, changed, .{ .skip_defaults = true });
    const text = try tmp.dir.readFileAlloc(std.testing.io, "settings.json", gpa, .limited(1024));
    defer gpa.free(text);
    try std.testing.expectEqualStrings("{\"volume\":0.5,\"bindings\":[{\"action\":\"jump\",\"key\":\"space\"}]}\n", text);

    const loaded = try json.loadAs(Settings, gpa, std.testing.io, path, .{});
    defer loaded.deinit();
    try std.testing.expectEqual(@as(f32, 0.5), loaded.value.volume);
    try std.testing.expectEqual(@as(u32, 1280), loaded.value.window.width);
    try std.testing.expectEqualStrings("space", loaded.value.bindings[0].key);
}
