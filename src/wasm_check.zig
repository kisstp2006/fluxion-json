// SPDX-License-Identifier: CC0-1.0

//! What `zig build test` compiles for `wasm32-freestanding` and never runs,
//! so a browser build that would not compile fails the suite and not a page.

const std = @import("std");
const json = @import("fluxion_json");

var heap: [256 * 1024]u8 = undefined;

const Save = struct {
    name: []const u8 = "",
    level: u16 = 1,
    position: struct { x: f32 = 0, y: f32 = 0 } = .{},
    items: []const []const u8 = &.{},
};

export fn fluxion_json_wasm_check(text: [*]const u8, len: usize) u32 {
    var fba: std.heap.FixedBufferAllocator = .init(&heap);
    const gpa = fba.allocator();

    const save = json.parseAs(Save, gpa, text[0..len], .{ .syntax = .json5 }) catch return 1;
    const doc = json.parse(gpa, text[0..len], .{}) catch return 2;
    doc.root.put("level", save.value.level + 1) catch return 3;
    const out = json.stringify(gpa, doc.root, .{ .indent = 2, .sort_keys = true }) catch return 4;
    if (!json.valid(out, .{})) return 5;
    return @intCast(out.len);
}
