// SPDX-License-Identifier: CC0-1.0

//! A round trip only proves the reader and the writer agree with each other,
//! so most of this is the other thing: what every JSON reader must take and
//! must refuse (the cases follow Nicolas Seriot's JSONTestSuite), random
//! trees written in every layout and read back, text damaged at random, a
//! cross-check against `std.json`, and every allocation failing in turn.

const std = @import("std");
const testing = std.testing;
const json = @import("root.zig");
const Value = json.Value;

const must_accept = [_][]const u8{
    "[[]   ]",                                 "[\"\"]",                             "[]",                               "[\"a\"]",
    "[false]",                                 "[null, 1, \"1\", {}]",               "[null]",                           "[1\n]",
    " [1]",                                    "[1,null,null,null,2]",               "[2] ",                             "[123e65]",
    "[0e+1]",                                  "[0e1]",                              "[ 4]",                             "[-0.0000000000000000000000001]\n",
    "[20e1]",                                  "[-0]",                               "[-123]",                           "[-1]",
    "[1E22]",                                  "[1E-2]",                             "[1E+2]",                           "[123e45]",
    "[123.456e78]",                            "[1e-2]",                             "[1e+2]",                           "[123]",
    "[123.456789]",                            "{\"asd\":\"sdf\"}",                  "{\"a\":\"b\",\"a\":\"c\"}",        "{\"a\":\"b\",\"a\":\"b\"}",
    "{}",                                      "{\"\":0}",                           "{\"foo\\u0000bar\": 42}",          "{\"a\":[]}",
    "{\n\"a\": \"b\"\n}",                      "[\"\\u0060\\u012a\\u12AB\"]",        "[\"\\uD801\\udc37\"]",             "[\"\\ud83d\\ude39\\ud83d\\udc8d\"]",
    "[\"\\\\u0000\"]",                         "[\"\\\"\"]",                         "[\"a/*b*/c/*d//e\"]",              "[\"\\\\a\"]",
    "[\"\\u0012\"]",                           "[\"\\uFFFF\"]",                      "[\"\\uDBFF\\uDFFF\"]",             "[\"new\\u00A0line\"]",
    "[\"\\u0000\"]",
    "[\"π\"]",
    "[\"\u{1BFFF}\"]",                         "[\"asd \"]",                         "\" \"",                            "[\"\\uD834\\uDd1e\"]",
    "[\"\u{2028}\"]",                          "[\"\u{2029}\"]",                     "2",                                "\"asd\"",
    "true",                                    "null",                               "-0.1",                             "\xEF\xBB\xBF{}",
    "[1e999999]",                              "[\"\\u0061\\u30af\\u30EA\\u30b9\"]", "[\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"]", "{\"asd\":\"sdf\", \"dfg\":\"fgh\"}",
    "{ \"min\": -1.0e+28, \"max\": 1.0e+28 }",
};

const must_refuse = [_][]const u8{
    "[1 true]",                 "[a\u{e5}]",            "[\"\": 1]",                    "[\"\"],",
    "[,1]",                     "[1,,2]",               "[\"x\",,]",                    "[\"x\"]]",
    "[\"\",]",                  "[\"x\"",               "[x",                           "[3[4]]",
    "[\xff]",                   "[1:2]",                "[,]",                          "[-]",
    "[   , \"\"]",              "[\"a\",\n4\n,1,",      "[1,]",                         "[1,,]",
    "[\"\x0b\"a\"\\f\"]",       "[*]",                  "[\"\"",                        "[1,",
    "[{}",                      "[\"a\" \"b\"]",        "[++1234]",                     "[+1]",
    "[+Inf]",                   "[-01]",                "[-1.0.]",                      "[-2.]",
    "[-NaN]",                   "[.-1]",                "[.2e-3]",                      "[0.1.2]",
    "[0.3e+]",                  "[0.3e]",               "[0.e1]",                       "[0E+]",
    "[0E]",                     "[0e+]",                "[0e]",                         "[1.0e+]",
    "[1.0e-]",                  "[1.0e]",               "[1 000.0]",                    "[1eE2]",
    "[2.e+3]",                  "[2.e-3]",              "[2.e3]",                       "[9.e+]",
    "[Inf]",                    "[NaN]",                "[\u{FF11}]",                   "[-foo]",
    "[- 1]",                    "[-012]",               "[-.123]",                      "[1.2a-3]",
    "[1ea]",                    "[012]",                "[\"\x00\"]",                   "{\"x\", null}",
    "{\"x\"::\"b\"}",           "{\u{1F1E8}\u{1F1ED}}", "{\"a\":\"a\" 123}",            "{key: 'value'}",
    "{\"a\" b}",                "{:\"b\"}",             "{\"a\" \"b\"}",                "{\"a\":",
    "{\"a\"",                   "{1:1}",                "{9999E9999:1}",                "{null:null,null:null}",
    "{\"id\":0,,,,,}",          "{'a':0}",              "{\"id\":0,}",                  "{\"a\":\"b\"}/**/",
    "{\"a\":\"b\"}/**//",       "{\"a\":\"b\"}//",      "{\"a\":\"b\"}/",               "{\"a\":\"b\",,\"c\":\"d\"}",
    "{a: \"b\"}",               "{\"a\":\"a",           "{ \"foo\" : \"bar\", \"a\" }", "{\"a\":\"b\"}#",
    " ",                        "[\"\\uD800\\\"]",      "[\"\\uD800\\u\"]",             "[\"\\uD800\\u1\"]",
    "[\"\\uD800\\u1x\"]",       "[\u{e9}]",             "[\"\\\x00\"]",                 "[\"\\\\\\\"]",
    "[\\n]",                    "[\"\\x00\"]",          "[\"\\u00A\"]",                 "[\"\\uD834\\uDd\"]",
    "[\"\\a\"]",                "[\"\\UA66D\"]",        "[\"\t\"]",                     "abc",
    "[\x00]",                   "2@",                   "{}}",                          "{\"\":",
    "{\"a\":/*comment*/\"b\"}", "{\"a\": true} \"x\"",  "[']",                          "['x']",
    "[\n",                      "[1]x",                 "[]]",                          "[\x0c]",
    "\xEF\xBB\xBF",             "[\u{00A0}1]",          "[\"\xc0\xaf\"]",               "[\"\xed\xa0\x80\"]",
    "[\"\x80\"]",               "[\"\xe0\xff\"]",       "[\"\xf4\x90\x80\x80\"]",       "[True]",
    "[tru]",                    "[nul]",                "[fals]",                       "[truex]",
    "",                         "{\"a\":1}}",           "[1]]",                         "\"\\u12\"",
};

test "what every JSON reader must accept, this one does" {
    for (must_accept) |text| {
        errdefer std.debug.print("refused: {s}\n", .{text});
        try testing.expect(json.valid(text, .{}));
        const doc = try json.parse(testing.allocator, text, .{});
        doc.deinit();
    }
}

test "what every JSON reader must refuse, this one does, and says where" {
    for (must_refuse) |text| {
        errdefer std.debug.print("accepted: {s}\n", .{text});
        try testing.expect(!json.valid(text, .{}));
        var diagnostics: json.Diagnostics = .{};
        if (json.parse(testing.allocator, text, .{ .diagnostics = &diagnostics })) |doc| {
            doc.deinit();
            return error.TestExpectedError;
        } else |_| {}
        try testing.expect(diagnostics.message().len > 0);
        try testing.expect(diagnostics.line >= 1);
    }
}

test "nesting a hundred thousand deep is refused, not followed" {
    const deep = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(deep);
    @memset(deep, '[');
    try testing.expect(!json.valid(deep, .{}));
    try testing.expectError(error.TooDeep, json.parse(testing.allocator, deep, .{}));
    try testing.expectError(error.TooDeep, json.parseAs([]const json.Value, testing.allocator, deep, .{}));
}

/// A random tree: scalars of every kind, strings with escapes and characters
/// from every UTF-8 length, and objects and arrays of every size up to a few.
fn randomValue(doc: json.Document, random: std.Random, depth: usize) !Value {
    const choice = random.uintLessThan(u8, if (depth > 4) 6 else 8);
    return switch (choice) {
        0 => .null,
        1 => .{ .bool = random.boolean() },
        2 => .{ .int = switch (random.uintLessThan(u8, 3)) {
            0 => random.intRangeAtMost(i64, -10, 10),
            1 => random.int(i64),
            else => random.intRangeAtMost(i64, -100_000, 100_000),
        } },
        3 => blk: {
            const f: f64 = switch (random.uintLessThan(u8, 3)) {
                0 => @floatFromInt(random.intRangeAtMost(i32, -100, 100)),
                1 => (random.float(f64) - 0.5) * 1e6,
                else => @bitCast(random.int(u64)),
            };
            break :blk .{ .float = if (std.math.isFinite(f)) f else 0.5 };
        },
        4, 5 => blk: {
            const pieces = [_][]const u8{ "a", "Z", " ", "\"", "\\", "/", "\n", "\t", "\x01", "é", "中", "😀", "\u{2028}", "~1", "{}", "[]", ",", ":" };
            var text: std.ArrayListUnmanaged(u8) = .empty;
            for (0..random.uintLessThan(usize, 12)) |_| try text.appendSlice(doc.allocator(), pieces[random.uintLessThan(usize, pieces.len)]);
            break :blk try doc.string(text.items);
        },
        6 => blk: {
            const array = try doc.array();
            for (0..random.uintLessThan(usize, 7)) |_| try array.append(try randomValue(doc, random, depth + 1));
            break :blk array;
        },
        else => blk: {
            const object = try doc.object();
            for (0..random.uintLessThan(usize, 7)) |i| {
                var name: [16]u8 = undefined;
                const key = std.fmt.bufPrint(&name, "k{d}{s}", .{ i, if (random.boolean()) "é\"" else "" }) catch unreachable;
                try object.put(key, try randomValue(doc, random, depth + 1));
            }
            break :blk object;
        },
    };
}

test "random trees read back equal, in every layout" {
    var prng = std.Random.DefaultPrng.init(0xF1D0);
    const random = prng.random();
    const layouts = [_]json.WriteOptions{
        .{},
        .{ .indent = 2 },
        .{ .indent = 4, .line_width = 0 },
        .{ .indent = 1, .line_width = 12 },
        .{ .indent = 2, .use_tabs = true, .line_width = 30 },
        .{ .indent = 2, .escape_unicode = true },
        .{ .sort_keys = true, .indent = 3, .line_width = 60 },
    };
    for (0..400) |_| {
        const doc: json.Document = try .init(testing.allocator);
        defer doc.deinit();
        const tree = try randomValue(doc, random, 0);
        for (layouts) |layout| {
            const text = try json.stringify(testing.allocator, tree, layout);
            defer testing.allocator.free(text);
            errdefer std.debug.print("layout {any} wrote:\n{s}\n", .{ layout, text });
            const back = try json.parse(testing.allocator, text, .{});
            defer back.deinit();
            try testing.expect(back.root.eql(tree));
            if (layout.indent > 0 and !layout.use_tabs) try expectLaidOut(text, layout.line_width);
            const again = try json.reformat(testing.allocator, text, .{}, .{ .escape_unicode = layout.escape_unicode });
            defer testing.allocator.free(again);
            const compact = try json.stringify(testing.allocator, tree, .{ .sort_keys = layout.sort_keys, .escape_unicode = layout.escape_unicode });
            defer testing.allocator.free(compact);
            try testing.expectEqualStrings(compact, again);
        }
    }
}

/// Every container on one line fits there, and every container spread over
/// lines would not have: worked out from the text as written, not from
/// anything the writer kept.
fn expectLaidOut(text: []const u8, width: usize) !void {
    var reader: json.Reader = .init(testing.allocator, text, .{});
    defer reader.deinit();
    var starts: [json.Reader.max_depth_limit]usize = undefined;
    var depth: usize = 0;
    while (try reader.next()) |token| switch (token) {
        .object_begin, .array_begin => {
            starts[depth] = reader.token_start;
            depth += 1;
        },
        .object_end, .array_end => {
            depth -= 1;
            const start = starts[depth];
            const span = text[start .. reader.token_start + 1];
            const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..start], '\n')) |i| i + 1 else 0;
            const column = start - line_start;
            const one_line = try oneLineLength(span);
            errdefer std.debug.print("container at column {d}, {d} wide on one line, width {d}:\n{s}\n", .{ column, one_line, width, span });
            if (std.mem.indexOfScalar(u8, span, '\n') != null) {
                if (width > 0) try testing.expect(column + one_line + 1 >= width);
            } else if (width > 0 and one_line > 2) {
                try testing.expect(column + one_line + 1 < width);
            } else {
                try testing.expectEqual(@as(usize, 2), span.len);
            }
        },
        else => {},
    };
}

fn oneLineLength(span: []const u8) !usize {
    var reader: json.Reader = .init(testing.allocator, span, .{});
    defer reader.deinit();
    var items: [json.Reader.max_depth_limit]usize = undefined;
    var objects: [json.Reader.max_depth_limit]bool = undefined;
    var depth: usize = 0;
    var total: usize = 0;
    var after_key = false;
    while (try reader.next()) |token| {
        const written = reader.pos - reader.token_start;
        switch (token) {
            .key => {
                total += @as(usize, if (items[depth - 1] == 0) 1 else 2) + written + 2;
                items[depth - 1] += 1;
                after_key = true;
                continue;
            },
            .object_end, .array_end => {
                depth -= 1;
                total += if (objects[depth] and items[depth] > 0) 2 else 1;
                continue;
            },
            else => {},
        }
        if (after_key) {
            after_key = false;
        } else if (depth > 0) {
            if (items[depth - 1] > 0) total += 2;
            items[depth - 1] += 1;
        }
        total += written;
        if (token == .object_begin or token == .array_begin) {
            objects[depth] = token == .object_begin;
            items[depth] = 0;
            depth += 1;
        }
    }
    return total;
}

test "damaged text never crashes the reader, in any syntax" {
    var prng = std.Random.DefaultPrng.init(0xBAD);
    const random = prng.random();
    const seeds = [_][]const u8{
        \\{"name": "Ada", "tags": ["a", "b\n\u00e9"], "pos": {"x": 1.5e3, "y": -2}, "ok": true, "none": null}
        ,
        \\[1, 2.5, -0, "x\\\"y", {"deep": [[[{}]]]}, false, 1e-7, "😀"]
        ,
        \\// c
        \\{unquoted: 'single', hex: 0x1F, lead: .5, trail: 5., inf: -Infinity, list: [1,2,],}
    };
    var buf: [256]u8 = undefined;
    for (0..20_000) |round| {
        const seed = seeds[round % seeds.len];
        @memcpy(buf[0..seed.len], seed);
        var len = seed.len;
        for (0..1 + random.uintLessThan(usize, 4)) |_| {
            const at = random.uintLessThan(usize, len + 1);
            switch (random.uintLessThan(u8, 3)) {
                0 => if (at < len) {
                    buf[at] = random.int(u8);
                },
                1 => if (len < buf.len) {
                    std.mem.copyBackwards(u8, buf[at + 1 .. len + 1], buf[at..len]);
                    buf[at] = "{}[]\",:\\/*'0e.-+ \nx"[random.uintLessThan(usize, 20)];
                    len += 1;
                },
                else => if (at < len) {
                    std.mem.copyForwards(u8, buf[at .. len - 1], buf[at + 1 .. len]);
                    len -= 1;
                },
            }
        }
        const text = buf[0..len];
        for ([_]json.Syntax{ .json, .jsonc, .json5 }) |syntax| {
            const accepted = if (json.parse(testing.allocator, text, .{ .syntax = syntax })) |doc| blk: {
                const written = try json.stringify(testing.allocator, doc.root, .{ .indent = 2 });
                defer testing.allocator.free(written);
                const back = try json.parse(testing.allocator, written, .{});
                defer back.deinit();
                try testing.expect(back.root.eql(doc.root) or hasNan(doc.root));
                doc.deinit();
                break :blk true;
            } else |err| switch (err) {
                error.SyntaxError, error.TooDeep => false,
                else => return err,
            };
            try testing.expectEqual(accepted, json.valid(text, .{ .syntax = syntax }));
        }
    }
}

fn hasNan(v: Value) bool {
    return switch (v) {
        .float => |f| !std.math.isFinite(f),
        .array => |a| for (a.items()) |item| {
            if (hasNan(item)) break true;
        } else false,
        .object => |o| for (o.values()) |item| {
            if (hasNan(item)) break true;
        } else false,
        else => false,
    };
}

test "the same trees as std.json reads" {
    var prng = std.Random.DefaultPrng.init(0x57D);
    const random = prng.random();
    for (0..300) |_| {
        const doc: json.Document = try .init(testing.allocator);
        defer doc.deinit();
        const tree = try randomValue(doc, random, 0);
        const text = try json.stringify(testing.allocator, tree, .{ .indent = 2 });
        defer testing.allocator.free(text);
        const theirs = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
        defer theirs.deinit();
        try expectSameAsStd(tree, theirs.value);
    }
}

fn expectSameAsStd(ours: Value, theirs: std.json.Value) !void {
    switch (ours) {
        .null => try testing.expect(theirs == .null),
        .bool => |b| try testing.expectEqual(b, theirs.bool),
        .int => |i| try testing.expectEqual(i, theirs.integer),
        .float => |f| try testing.expectEqual(f, theirs.float),
        .string => |s| try testing.expectEqualStrings(s, theirs.string),
        .array => |a| {
            try testing.expectEqual(a.len(), theirs.array.items.len);
            for (a.items(), theirs.array.items) |x, y| try expectSameAsStd(x, y);
        },
        .object => |o| {
            try testing.expectEqual(o.len(), theirs.object.count());
            for (o.keys(), o.values(), theirs.object.keys(), theirs.object.values()) |k, v, tk, tv| {
                try testing.expectEqualStrings(k, tk);
                try expectSameAsStd(v, tv);
            }
        },
    }
}

const Save = struct {
    name: []const u8 = "",
    level: u16 = 1,
    items: []const struct { id: u32, tags: []const []const u8 = &.{} } = &.{},
    extra: Value = .null,
    kind: union(enum) { warrior: struct { rage: u8 }, mage, rogue: []const u8 } = .mage,
};

fn everything(gpa: std.mem.Allocator) !void {
    const text =
        \\{"name": "Ada", "level": 3, "items": [{"id": 1, "tags": ["a", "b\u00e9"]}, {"id": 2}],
        \\ "extra": {"any": [1, {"thing": null}]}, "kind": {"warrior": {"rage": 9}}}
    ;
    var doc = try json.parse(gpa, text, .{});
    defer doc.deinit();
    try doc.root.put("level", 4);
    try doc.root.get("items").append(.{ .id = 3, .tags = .{"c"} });
    const typed = try doc.root.parseAs(Save, gpa, .{});
    defer typed.deinit();
    const direct = try json.parseAs(Save, gpa, text, .{});
    defer direct.deinit();
    const written = try json.stringify(gpa, typed.value, .{ .indent = 2, .sort_keys = true });
    defer gpa.free(written);
    const pretty = try json.reformat(gpa, written, .{}, .{ .indent = 4 });
    defer gpa.free(pretty);
    const copy = try doc.clone(doc.root);
    try doc.merge(copy);
}

test "every allocation that can fail, failing, leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, everything, .{});
}
