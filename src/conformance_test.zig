// SPDX-License-Identifier: CC0-1.0

//! A round trip only proves the reader and the writer agree with each other,
//! so most of this is the other thing: what every JSON reader must take and
//! must refuse (the cases follow Nicolas Seriot's JSONTestSuite), RFC 8949's
//! own CBOR examples, random trees written in every layout and in CBOR and
//! read back, text and CBOR damaged at random, a cross-check against
//! `std.json`, and every allocation failing in turn.

const std = @import("std");
const testing = std.testing;
const json = @import("root.zig");
const Value = json.Value;
const hex = @import("cbor.zig").hex;

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

/// RFC 8949's Appendix A, with the JSON each example reads as. Byte strings
/// become base64url text, whatever a tag on them hints, and tags are passed
/// over to what they tag.
const rfc8949_examples = [_]struct { []const u8, []const u8 }{
    .{ &hex("00"), "0" },
    .{ &hex("01"), "1" },
    .{ &hex("0a"), "10" },
    .{ &hex("17"), "23" },
    .{ &hex("1818"), "24" },
    .{ &hex("1819"), "25" },
    .{ &hex("1864"), "100" },
    .{ &hex("1903e8"), "1000" },
    .{ &hex("1a000f4240"), "1000000" },
    .{ &hex("1b000000e8d4a51000"), "1000000000000" },
    .{ &hex("1bffffffffffffffff"), "18446744073709551615" },
    .{ &hex("3bffffffffffffffff"), "-18446744073709551616" },
    .{ &hex("20"), "-1" },
    .{ &hex("29"), "-10" },
    .{ &hex("3863"), "-100" },
    .{ &hex("3903e7"), "-1000" },
    .{ &hex("f90000"), "0.0" },
    .{ &hex("f98000"), "-0.0" },
    .{ &hex("f93c00"), "1.0" },
    .{ &hex("fb3ff199999999999a"), "1.1" },
    .{ &hex("f93e00"), "1.5" },
    .{ &hex("f97bff"), "65504.0" },
    .{ &hex("fa47c35000"), "100000.0" },
    .{ &hex("fa7f7fffff"), "3.4028234663852886e+38" },
    .{ &hex("fb7e37e43c8800759c"), "1e+300" },
    .{ &hex("f90001"), "5.960464477539063e-8" },
    .{ &hex("f90400"), "0.00006103515625" },
    .{ &hex("f9c400"), "-4.0" },
    .{ &hex("fbc010666666666666"), "-4.1" },
    .{ &hex("f97c00"), "Infinity" },
    .{ &hex("f97e00"), "NaN" },
    .{ &hex("f9fc00"), "-Infinity" },
    .{ &hex("fa7f800000"), "Infinity" },
    .{ &hex("fa7fc00000"), "NaN" },
    .{ &hex("faff800000"), "-Infinity" },
    .{ &hex("fb7ff0000000000000"), "Infinity" },
    .{ &hex("fb7ff8000000000000"), "NaN" },
    .{ &hex("fbfff0000000000000"), "-Infinity" },
    .{ &hex("f4"), "false" },
    .{ &hex("f5"), "true" },
    .{ &hex("f6"), "null" },
    .{ &hex("f7"), "null" },
    .{ &hex("c074323031332d30332d32315432303a30343a30305a"), "\"2013-03-21T20:04:00Z\"" },
    .{ &hex("c11a514b67b0"), "1363896240" },
    .{ &hex("c1fb41d452d9ec200000"), "1363896240.5" },
    .{ &hex("d74401020304"), "\"AQIDBA\"" },
    .{ &hex("d818456449455446"), "\"ZElFVEY\"" },
    .{ &hex("d82076687474703a2f2f7777772e6578616d706c652e636f6d"), "\"http://www.example.com\"" },
    .{ &hex("40"), "\"\"" },
    .{ &hex("4401020304"), "\"AQIDBA\"" },
    .{ &hex("60"), "\"\"" },
    .{ &hex("6161"), "\"a\"" },
    .{ &hex("6449455446"), "\"IETF\"" },
    .{ &hex("62225c"), "\"\\\"\\\\\"" },
    .{ &hex("62c3bc"), "\"ü\"" },
    .{ &hex("63e6b0b4"), "\"水\"" },
    .{ &hex("64f0908591"), "\"𐅑\"" },
    .{ &hex("80"), "[]" },
    .{ &hex("83010203"), "[1,2,3]" },
    .{ &hex("8301820203820405"), "[1,[2,3],[4,5]]" },
    .{ &hex("98190102030405060708090a0b0c0d0e0f101112131415161718181819"), one_to_25 },
    .{ &hex("a0"), "{}" },
    .{ &hex("a26161016162820203"), "{\"a\":1,\"b\":[2,3]}" },
    .{ &hex("826161a161626163"), "[\"a\",{\"b\":\"c\"}]" },
    .{ &hex("a56161614161626142616361436164614461656145"), "{\"a\":\"A\",\"b\":\"B\",\"c\":\"C\",\"d\":\"D\",\"e\":\"E\"}" },
    .{ &hex("5f42010243030405ff"), "\"AQIDBAU\"" },
    .{ &hex("7f657374726561646d696e67ff"), "\"streaming\"" },
    .{ &hex("9fff"), "[]" },
    .{ &hex("9f018202039f0405ffff"), "[1,[2,3],[4,5]]" },
    .{ &hex("9f01820203820405ff"), "[1,[2,3],[4,5]]" },
    .{ &hex("83018202039f0405ff"), "[1,[2,3],[4,5]]" },
    .{ &hex("83019f0203ff820405"), "[1,[2,3],[4,5]]" },
    .{ &hex("9f0102030405060708090a0b0c0d0e0f101112131415161718181819ff"), one_to_25 },
    .{ &hex("bf61610161629f0203ffff"), "{\"a\":1,\"b\":[2,3]}" },
    .{ &hex("826161bf61626163ff"), "[\"a\",{\"b\":\"c\"}]" },
    .{ &hex("bf6346756ef563416d7421ff"), "{\"Fun\":true,\"Amt\":-2}" },
};

const one_to_25 = "[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25]";

/// The rest of Appendix A: big numbers, maps with numbers for keys, and
/// simple values with no meaning yet.
const rfc8949_refused = [_][]const u8{
    &hex("c249010000000000000000"),
    &hex("c349010000000000000000"),
    &hex("a201020304"),
    &hex("f0"),
    &hex("f8ff"),
};

test "RFC 8949's examples read as JSON, or are refused when JSON cannot hold them" {
    for (rfc8949_examples) |example| {
        const bytes, const expected = example;
        errdefer std.debug.print("example {x}\n", .{bytes});
        const text = try json.reformat(testing.allocator, bytes, .{ .format = .cbor }, .{ .non_finite = .literal });
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(expected, text);
        try testing.expect(json.valid(bytes, .{ .format = .cbor }));
    }
    for (rfc8949_refused) |bytes| {
        errdefer std.debug.print("accepted {x}\n", .{bytes});
        try testing.expect(!json.valid(bytes, .{ .format = .cbor }));
        var diagnostics: json.Diagnostics = .{};
        try testing.expectError(error.SyntaxError, json.parse(testing.allocator, bytes, .{ .format = .cbor, .diagnostics = &diagnostics }));
        try testing.expect(diagnostics.binary and diagnostics.message().len > 0);
    }
}

test "nesting a hundred thousand deep is refused, not followed" {
    const deep = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(deep);
    @memset(deep, '[');
    try testing.expect(!json.valid(deep, .{}));
    try testing.expectError(error.TooDeep, json.parse(testing.allocator, deep, .{}));
    try testing.expectError(error.TooDeep, json.parseAs([]const json.Value, testing.allocator, deep, .{}));

    @memset(deep, 0x81);
    try testing.expect(!json.valid(deep, .{ .format = .cbor }));
    try testing.expectError(error.TooDeep, json.parse(testing.allocator, deep, .{ .format = .cbor }));
    deep[1000] = 0x00;
    try testing.expect(json.valid(deep[0..1001], .{ .format = .cbor, .max_depth = json.Reader.max_depth_limit }));
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

test "random trees read back equal through CBOR, and come out as the same JSON" {
    var prng = std.Random.DefaultPrng.init(0xCB0);
    const random = prng.random();
    for (0..400) |_| {
        const doc: json.Document = try .init(testing.allocator);
        defer doc.deinit();
        const tree = try randomValue(doc, random, 0);
        const bytes = try json.stringify(testing.allocator, tree, .{ .format = .cbor });
        defer testing.allocator.free(bytes);
        try testing.expect(json.valid(bytes, .{}));
        const back = try json.parse(testing.allocator, bytes, .{});
        defer back.deinit();
        try testing.expect(back.root.eql(tree));

        // Every number the kind it was, in the same digits.
        const text = try json.stringify(testing.allocator, tree, .{});
        defer testing.allocator.free(text);
        const converted = try json.reformat(testing.allocator, bytes, .{}, .{});
        defer testing.allocator.free(converted);
        try testing.expectEqualStrings(text, converted);

        const recoded = try json.reformat(testing.allocator, text, .{}, .{ .format = .cbor });
        defer testing.allocator.free(recoded);
        try testing.expectEqualSlices(u8, bytes, recoded);
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

test "damaged CBOR never crashes the reader, and valid agrees with parse" {
    var prng = std.Random.DefaultPrng.init(0xBADCB0);
    const random = prng.random();
    const seeds = [_][]const u8{
        &hex("d9d9f7 bf 646e616d65 63416461 6474616773 82 6161 7f 6162 6163 ff 63706f73 a2 6178 f93e00 6179 fa3dcccccd 626f6b f5 646e6f6e65 f6 ff"),
        &hex("9f 01 fb3ff199999999999a 20 3903e7 5f 4201ff 4103 ff c1 1a514b67b0 81 81 81 a0 1bffffffffffffffff 64f0908591 ff"),
        &hex("a3 6161 d818 4401020304 6162 9f bf ff 80 ff 6163 bf 6164 f97c00 ff"),
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
                    buf[at] = if (random.boolean()) random.int(u8) else "\xff\x9f\xbf\x7f\x5f\x18\x1b\xf9\xfb\xc2\xd9\x00"[random.uintLessThan(usize, 12)];
                    len += 1;
                },
                else => if (at < len) {
                    std.mem.copyForwards(u8, buf[at .. len - 1], buf[at + 1 .. len]);
                    len -= 1;
                },
            }
        }
        const bytes = buf[0..len];
        var diagnostics: json.Diagnostics = .{};
        const accepted = if (json.parse(testing.allocator, bytes, .{ .format = .cbor, .diagnostics = &diagnostics })) |doc| blk: {
            defer doc.deinit();
            const written = try json.stringify(testing.allocator, doc.root, .{ .format = .cbor, .non_finite = .literal });
            defer testing.allocator.free(written);
            const back = try json.parse(testing.allocator, written, .{});
            defer back.deinit();
            try testing.expect(back.root.eql(doc.root) or hasNan(doc.root));
            break :blk true;
        } else |err| switch (err) {
            error.SyntaxError, error.TooDeep => blk: {
                try testing.expect(diagnostics.binary and diagnostics.message().len > 0);
                break :blk false;
            },
            else => return err,
        };
        try testing.expectEqual(accepted, json.valid(bytes, .{ .format = .cbor }));
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

    const bytes = try json.stringify(gpa, typed.value, .{ .format = .cbor });
    defer gpa.free(bytes);
    const from_cbor = try json.parseAs(Save, gpa, bytes, .{});
    defer from_cbor.deinit();
    const cbor_as_text = try json.reformat(gpa, bytes, .{}, .{ .indent = 2 });
    defer gpa.free(cbor_as_text);
    // Strings in parts and byte strings, which take memory of their own.
    const pieces = try json.parse(gpa, &hex("d9d9f7 a2 7f 6161 6162 ff 5f 4101 4102 ff 6163 83 01 fa3dcccccd 4401020304"), .{});
    defer pieces.deinit();
}

test "every allocation that can fail, failing, leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, everything, .{});
}
