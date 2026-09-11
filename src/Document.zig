// SPDX-License-Identifier: CC0-1.0

//! A JSON value and the memory it lives in: what `json.parse` and
//! `json.load` hand back, and where a tree is built from nothing.
//!
//! ```zig
//! var doc: json.Document = try .init(gpa);
//! defer doc.deinit();
//! doc.root = try doc.from(.{ .name = "Ada", .tags = .{ "mage", "healer" } });
//! try doc.root.put("level", 3);
//! ```
//!
//! Everything in a document is freed by `deinit` and nothing else, so no
//! value taken out of it needs freeing, and none is usable after.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;

const value_mod = @import("value.zig");
const Value = value_mod.Value;
const EditError = value_mod.EditError;

const Document = @This();

/// On the heap so the document can be moved: every object and array in it
/// holds this pointer, and a copy of an arena kept inside would leave them
/// pointing at the old one.
arena: *ArenaAllocator,
root: Value = .null,

pub fn init(gpa: Allocator) Allocator.Error!Document {
    const arena = try gpa.create(ArenaAllocator);
    arena.* = .init(gpa);
    return .{ .arena = arena };
}

pub fn deinit(doc: Document) void {
    const gpa = doc.arena.child_allocator;
    doc.arena.deinit();
    gpa.destroy(doc.arena);
}

/// The document's own memory, for anything that should live and die with it.
pub fn allocator(doc: Document) Allocator {
    return doc.arena.allocator();
}

/// A new, empty object.
pub fn object(doc: Document) Allocator.Error!Value {
    return .{ .object = try value_mod.newObject(doc.arena) };
}

/// A new, empty array.
pub fn array(doc: Document) Allocator.Error!Value {
    return .{ .array = try value_mod.newArray(doc.arena) };
}

/// A string copied into the document.
pub fn string(doc: Document, text: []const u8) Allocator.Error!Value {
    return .{ .string = try doc.allocator().dupe(u8, text) };
}

/// Any Zig value as a `Value` in this document: `3`, `"text"`, a struct, a
/// slice, an anonymous literal such as `.{ .x = 1, .tags = .{ "a", "b" } }`.
/// A `Value` already in this document is returned as it is.
pub fn from(doc: Document, value: anytype) EditError!Value {
    return value_mod.toValue(doc.arena, value);
}

/// A copy of `value`, however deep, that shares nothing with it.
pub fn clone(doc: Document, value: Value) EditError!Value {
    return value_mod.build(doc.arena, value);
}

/// Apply `patch` to the root as a JSON Merge Patch (RFC 7386): its members
/// replace or add members of the same name, recursing into objects, a
/// `null` removes one, and a patch that is not an object replaces the root.
pub fn merge(doc: *Document, patch: Value) EditError!void {
    doc.root = try value_mod.mergeInto(doc.arena, doc.root, patch, 0);
}

test "a tree built from nothing" {
    var doc: Document = try .init(testing.allocator);
    defer doc.deinit();
    doc.root = try doc.object();
    try doc.root.put("name", "Ada");
    try doc.root.put("pos", .{ .x = 1.5, .y = -2 });
    const tags = try doc.array();
    try tags.append("mage");
    try doc.root.put("tags", tags);
    try tags.append("healer");
    try testing.expectEqualStrings("healer", doc.root.at("/tags/1").asString().?);
    try testing.expectEqual(@as(?f32, 1.5), doc.root.at("/pos/x").asFloat(f32));

    const copy = try doc.clone(doc.root);
    try copy.put("name", "Grace");
    try testing.expectEqualStrings("Ada", doc.root.get("name").asString().?);
}

test "a document can be moved, and its values keep working" {
    const make = struct {
        fn make() !Document {
            var doc: Document = try .init(testing.allocator);
            errdefer doc.deinit();
            doc.root = try doc.from(.{ .list = .{ 1, 2 } });
            return doc;
        }
    }.make;
    var moved = try make();
    defer moved.deinit();
    try moved.root.get("list").append(3);
    try testing.expectEqual(@as(usize, 3), moved.root.get("list").len());
}

test "merge replaces the root when the patch is not an object" {
    var doc: Document = try .init(testing.allocator);
    defer doc.deinit();
    doc.root = try doc.from(.{ .a = 1 });
    try doc.merge(.{ .int = 7 });
    try testing.expectEqual(Value{ .int = 7 }, doc.root);
    try doc.merge(try doc.from(.{ .b = 2 }));
    try testing.expectEqual(@as(?i32, 2), doc.root.get("b").asInt(i32));
}
