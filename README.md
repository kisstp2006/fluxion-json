# Fluxion JSON

Read, write, load and save JSON in Zig 0.16: straight into your own types, or
as a tree to walk and change, with the calls you already know from
JavaScript, Python, C# and Rust.

| Piece | What it is |
| --- | --- |
| `parse`, `parseAs` | JSON text into a tree, or into your own types. |
| `stringify`, `write`, `fmt` | Any value back out as text, compact or laid out. |
| `load`, `loadAs`, `save` | The same, for files. Saving is atomic. |
| `.format = .cbor` | All of the above in binary: CBOR (RFC 8949), the same values in fewer bytes. |
| `Value`, `Document` | The tree: objects and arrays to read, change and build. |
| `Reader`, `Writer` | One token at a time, for everything else. |
| `Diagnostics` | Where reading went wrong and why, with the line and a caret under it. |

```zig
const json = @import("fluxion_json");

const Settings = struct {
    title: []const u8 = "Untitled",
    volume: f32 = 0.8,
    window: struct { width: u32 = 1280, height: u32 = 720, fullscreen: bool = false } = .{},
    difficulty: enum { easy, normal, hard } = .normal,
};

// Into a struct. Fields the file leaves out keep their defaults.
const settings = try json.loadAs(Settings, gpa, io, "settings.json", .{});
defer settings.deinit();

// Or as a tree, like JSON.parse. Anything missing reads as null.
const doc = try json.parse(gpa, text, .{});
defer doc.deinit();
const hp = doc.root.get("player").get("stats").get("hp").asInt(i32) orelse 100;

// And back out, like JSON.stringify.
try json.save(io, "settings.json", settings.value, .{ .indent = 2 });
```

## A tour

### Read a tree

```zig
const doc = try json.parse(gpa,
    \\{ "name": "Ada", "level": 7, "inventory": [{ "item": "sword" }, { "item": "potion", "count": 3 }] }
, .{});
defer doc.deinit();

const root = doc.root;
root.get("name").asString()                    // "Ada"
root.get("level").asInt(u32)                   // 7
root.get("inventory").get(-1).get("count")     // the last item's count: 3
root.at("/inventory/0/item").asString()        // a JSON Pointer: "sword"
root.get("mana").asInt(u32) orelse 100         // nothing there: 100

for (root.get("inventory").items()) |slot| { ... }
for (root.keys(), root.values()) |key, value| { ... }
```

`get` takes a key or an index, and an index below zero counts from the end.
Whatever is missing - a key, an index past the end, anything asked of a value
that is not an object or an array - reads as `.null`, so a chain of lookups
cannot crash, and `orelse` gives the default. It is `?.` and `??` from
JavaScript, spelt the Zig way. `has` tells a missing member from one that is
`null`.

The `as` functions convert and never guess: `asInt(u8)` of `300` is `null`
because it does not fit, of `3.0` is `3`, and of `"3"` is `null` because a
string is not a number. There are `asBool`, `asInt`, `asFloat`, `asString`,
`asEnum`, `asArray` and `asObject`, and `typeName` says `"number"` or
`"object"` the way `typeof` would.

### Read into your own types

```zig
const Level = struct {
    name: []const u8,
    size: [2]u32,
    spawn: struct { x: f32, y: f32 } = .{ .x = 0, .y = 0 },
    enemies: []const Enemy = &.{},
    music: ?[]const u8 = null,
};

const level = try json.parseAs(Level, gpa, text, .{});
defer level.deinit();
level.value.enemies[0].hp
```

A field the text leaves out takes its default, or `null` if it is optional,
and one with neither is `error.MissingField`. A member the struct has no
field for is passed over, so a file written by a newer version of the game
still loads; `.unknown_fields = .fail` refuses it instead, and suggests the
field it was probably meant to be. Everything the result points at lives in
its own memory, freed by `deinit`, so the text can be freed as soon as
`parseAs` returns.

A field of type `json.Value` takes whatever is there, as a tree: the escape
hatch for a part of a file with no fixed shape. And a tree already in memory
converts the same way, with `value.parseAs(T, gpa, .{})`.

### Write

```zig
const text = try json.stringify(gpa, level.value, .{});                // compact, like JSON.stringify
const pretty = try json.stringify(gpa, level.value, .{ .indent = 2 });  // laid out
try json.write(&file_writer.interface, value, .{ .indent = 4 });       // into any std.Io.Writer
std.debug.print("{f}\n", .{json.fmt(value, .{ .indent = 2 })});        // inside print
```

Laid-out output keeps on one line whatever fits there, and wraps a long list
of plain values at the line width, rather than giving every number a line of
its own:

```json
{
  "name": "Ada",
  "inventory": [
    { "item": "sword", "damage": 12 },
    { "item": "map", "marks": [3, 14, 15, 92] }
  ],
  "tiles": [
    0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 0, 1, 1, 2, 3, 5, 8, 13,
    21, 34, 55
  ]
}
```

| Option | What it does |
| --- | --- |
| `indent` | Spaces per level. `0`, the default, writes one line with no spaces at all. |
| `use_tabs` | A tab per level instead. |
| `line_width` | Where the layout breaks lines; `80` by default. `0` gives every item its own line, as JavaScript does. |
| `sort_keys` | Every object's members in alphabetical order, as Python's `sort_keys`. |
| `escape_unicode` | ASCII-only output: everything else as `\u` escapes. |
| `skip_nulls` | Leave out struct fields that are `null`. |
| `skip_defaults` | Leave out struct fields that hold their default, so a settings file lists only what the player changed. |
| `non_finite` | What NaN and infinity become: `null` as in JavaScript (the default), `NaN` and `Infinity` as in JSON5, or `error.NonFiniteNumber`. |

Floats come out in the fewest digits that read back as exactly the same
float, and an `f32` in the fewest digits of an `f32`: `0.1`, not
`0.10000000149011612`. A whole float keeps its `.0`, so it reads back as a
float.

### Files

```zig
const doc = try json.load(gpa, io, "config.json", .{});
const config = try json.loadAs(Config, gpa, io, "config.json", .{});
try json.save(io, "saves/slot1.json", save_data, .{ .indent = 2 });
```

`save` writes the new file beside the old one and then puts it in its place,
so a crash or a power cut halfway through a save leaves the old file whole
rather than half a new one. It makes the directories on the way if they are
missing, and ends the file with a line break. A path is relative to the
working directory; for anything else - a pack file, an asset system - read
the bytes yourself and call `parse` or `parseAs`.

### Binary: CBOR

Every call above reads and writes CBOR too: RFC 8949, the binary form of the
same values. It is for the files only your own program opens - a save, a
level, a cache - where nobody reads the text. A tile map of numbers takes
57% of the bytes it takes as text, and records of strings 82%; writing is
half as fast again, and reading takes about as long as reading the text.

```zig
try json.save(io, "saves/slot1.cbor", save_data, .{ .format = .cbor });
const slot = try json.loadAs(Save, gpa, io, "saves/slot1.cbor", .{});  // no need to say which
const text = try json.reformat(gpa, bytes, .{}, .{ .indent = 2 });     // to look inside one
```

Reading tells the two apart on its own. Everything written as CBOR starts
with the three bytes RFC 8949 sets aside for saying "this is CBOR",
`D9 D9 F7`, which no JSON text can start with. CBOR from another program may
not start with them, and is read with `.format = .cbor`.

It is one model with two spellings, so a struct reads the same from either,
and a file converts from one to the other and back without losing anything.
Where CBOR holds more than JSON, it is read the way RFC 8949 turns it into
JSON: a byte string becomes base64url text, and a tag is passed over to what
it tags. What JSON has no room for - a map with numbers for keys, a big
number - is refused, with a message that says which byte it is at:

```
level.cbor: byte 1822: a key must be text for JSON, and this map has a number as one
```

A number takes as few bytes as hold it exactly - three for `1.5`, five for
most `f32`s - and reads back as exactly the value written. That has one
consequence to know about. An `f32` `0.1` really holds `0.100000001490116...`: JSON text
writes it as `0.1` because those are all the digits an `f32` has, but CBOR
keeps the float itself. Read back into an `f32` it is the same `0.1` both
ways; read into an `f64`, or into a tree, from CBOR it is the value the `f32`
really held.

Of the writing options, `sort_keys`, `skip_nulls`, `skip_defaults` and
`non_finite` apply to CBOR, and the layout ones do not. `non_finite =
.literal` writes NaN and the infinities as the floats they are.

### Change and build a tree

```zig
var doc: json.Document = try .init(gpa);
defer doc.deinit();

doc.root = try doc.from(.{ .name = "Ada", .level = 1, .tags = .{ "mage", "healer" } });
try doc.root.put("level", 2);
try doc.root.put("position", .{ .x = 1.5, .y = -2 });
try doc.root.get("tags").append("rogue");
_ = doc.root.remove("name");
```

`put` and `append` take a `Value` or any Zig value at all, anonymous
literals included, and copy it into the document. Objects and arrays are
shared the way they are in JavaScript and Python: a `Value` is a handle, so
changing `root.get("tags")` changes the array inside `root`. A value from
another document is copied in rather than shared, so nothing points into a
document that has been freed. Keys keep the order they were written or added
in.

`doc.object()`, `doc.array()` and `doc.string(...)` make new ones,
`doc.clone(value)` copies one deeply, and `value.eql(other)` compares two by
what they hold - `1` equals `1.0`, and members in any order.

`merge` is JSON Merge Patch (RFC 7386), which is exactly how settings sit over
defaults: every member of the patch replaces or adds the member of that name,
objects merge all the way down, and a `null` removes the member.

```zig
var settings = try json.load(gpa, io, "defaults.json", .{});
const mine = try json.load(gpa, io, "settings.json", .{ .syntax = .jsonc });
try settings.merge(mine.root);
```

### When something is wrong

Every read fails with a plain Zig error - `error.SyntaxError`,
`error.WrongType`, `error.MissingField` and so on - and fills in a
`Diagnostics` if it is given one:

```zig
var diagnostics: json.Diagnostics = .{};
const config = json.loadAs(Config, gpa, io, "config.json", .{ .diagnostics = &diagnostics }) catch |err| {
    std.debug.print("{s}: {f}\n", .{ @errorName(err), diagnostics });
    return err;
};
```

```
WrongType: config.json:3:24: expected a whole number, found the string "wide" (at /window/width)
      "window": { "width": "wide" }
                           ^
```

The messages say what to write instead where they can:

```
JSON does not allow a comma before ']' (.jsonc and .json5 do)
keys need double quotes in JSON: "name" (unquoted keys are JSON5)
JSON is case-sensitive: write true, not True
JSON has no None: an empty value is written null
the text ends before the object opened at line 3, column 5 is closed
there is no field "volumne"; did you mean "volume"?
"hardd" is not one of the values this can take; did you mean "hard"?
300 does not fit in a u8, which holds 0 to 255
```

The line and column count characters, so they match an editor. A line too
long to show - one minified file - is cut down to the part around the
problem.

## Coming from another language

| You would write | Here it is |
| --- | --- |
| `JSON.parse(text)`, `json.loads(s)` | `json.parse(gpa, text, .{})` |
| `JSON.stringify(v, null, 2)`, `json.dumps(v, indent=2)` | `json.stringify(gpa, v, .{ .indent = 2 })` |
| `json.load(f)`, `json.dump(obj, f)` | `json.load(gpa, io, path, .{})`, `json.save(io, path, obj, .{})` |
| `a?.b?.[0] ?? 5` | `a.get("b").get(0).asInt(i32) orelse 5` |
| `JsonSerializer.Deserialize<T>(text)`, `serde_json::from_str::<T>` | `json.parseAs(T, gpa, text, .{})` |
| `JsonNode.Parse(text)["a"]["b"]`, `v["a"]["b"]` | `(try json.parse(gpa, text, .{})).root.get("a").get("b")` |
| `v.pointer("/a/0")`, `j.at("/a/0")` | `v.at("/a/0")` |
| `j.value("volume", 0.8)` | `v.get("volume").asFloat(f32) orelse 0.8` |
| `j.contains("key")`, `"key" in d` | `v.has("key")` |
| `j.merge_patch(p)` | `doc.merge(p)` |
| `json.Valid(data)`, `json::accept` | `json.valid(text, .{})` |
| `json.Indent(dst, src, "", "  ")` | `json.reformat(gpa, text, .{}, .{ .indent = 2 })` |
| `sort_keys=True` | `.{ .sort_keys = true }` |
| `#[serde(rename_all = "camelCase")]`, a naming policy | `pub const json_case = .camel;` |
| `#[serde(rename = "type")]`, `json:"type"` | `pub const json_rename = .{ .kind = "type" };` |
| `#[serde(skip)]`, `json:"-"`, `[JsonIgnore]` | `pub const json_ignore = .{ .cache };` |
| `#[serde(tag = "type")]` | `pub const json_tag = "type";` |
| `omitempty`, `WhenWritingNull` | `.{ .skip_nulls = true }`, `.{ .skip_defaults = true }` |
| `DisallowUnknownFields()`, `deny_unknown_fields` | `.{ .unknown_fields = .fail }` |
| `toJSON()`, Dart's `toJson` and `fromJson` | `pub fn toJson(...)` and `pub fn fromJson(...)` |
| `JsonCommentHandling.Skip`, `AllowTrailingCommas` | `.{ .syntax = .jsonc }` |
| `cbor2.dumps(v)`, `serde_cbor::to_vec(&v)` | `json.stringify(gpa, v, .{ .format = .cbor })` |
| `cbor2.loads(b)`, `serde_cbor::from_slice::<T>(&b)` | `json.parse(gpa, bytes, .{})`, `json.parseAs(T, gpa, bytes, .{})` |

## What it decides for you, and why

**Missing reads as null.** A chain of `get` calls never fails, so reading
an optional setting is one line with a default, as it is in JavaScript. When
the difference matters, `has` and `Object.getPtr` tell a missing member from
a `null` one, and `parseAs` with no default for a field refuses a file
without it.

**Unknown members are passed over.** JavaScript, Python, Go, C# and serde
all do this, and a game needs it: a save written by version 1.2 still loads
in 1.1. The cost is a misspelt key going unnoticed, which is why
`.unknown_fields = .fail` exists, and why it names the field you meant.

**The last of two equal keys wins, in the first one's place**, as in
JavaScript and Python. `.duplicate_keys = .first` keeps the first, and
`.fail` refuses the text.

**Strict JSON unless asked otherwise.** A file this accepts is a file every
other program accepts too. Comments and trailing commas are one option
away, `.syntax = .jsonc`, and all of JSON5 another, `.syntax = .json5` - and
the error for a comment in strict JSON says so. A UTF-8 byte order mark at
the start is passed over whatever the syntax, because Windows editors write
one.

**Numbers keep what kind they were.** `3` reads as an integer and `3.0` as a
float, as in Python; a whole float is written with its `.0` so it reads back
the same way. In a tree an integer is an `i64`, and one too big for that is a
float, as in JavaScript. Read into a `u64` field and it is exact to the last
digit.

**Text is UTF-8 and nothing else.** Reading refuses bytes that are not
UTF-8, rather than passing corruption on. Writing replaces each such byte
with U+FFFD, so the output is valid even when the input was not, and an
escaped half of a surrogate pair reads as U+FFFD too.

**Nesting is limited.** 512 levels by default, `max_depth` up to 1024: a
file cannot run the reader out of stack, and neither can a tree that
contains itself, which writing refuses with `error.TooDeep`.

## Shaping how a type is written

A struct, union or enum can change its own spelling with declarations, and
every one of them is checked when it compiles: a rename naming a field the
type does not have is a compile error, not a rename that silently does
nothing.

```zig
const Accessor = struct {
    buffer_view: u32,           // "bufferView"
    byte_offset: u32 = 0,       // "byteOffset"
    kind: Kind,                 // "type"
    cache: ?*Buffer = null,     // never read or written

    pub const json_case = .camel;                  // or .pascal, .kebab
    pub const json_rename = .{ .kind = "type" };
    pub const json_ignore = .{.cache};
};

const Shape = union(enum) {
    circle: struct { radius: f32 },
    rect: struct { w: f32, h: f32 },
    point,

    pub const json_tag = "type";   // {"type": "circle", "radius": 2} instead of {"circle": {"radius": 2}}
};
```

A type can also write and read itself, when its JSON is not its fields:

```zig
const Color = struct {
    r: u8, g: u8, b: u8,

    pub fn toJson(c: Color, w: *json.Writer) json.Writer.Error!void {
        var buf: [7]u8 = undefined;
        try w.writeString(std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }) catch unreachable);
    }

    pub fn fromJson(value: json.Value, allocator: std.mem.Allocator) json.Error!Color {
        _ = allocator;
        const hex = value.asString() orelse return error.WrongType;
        const n = std.fmt.parseInt(u24, hex[1..], 16) catch return error.WrongType;
        return .{ .r = @truncate(n >> 16), .g = @truncate(n >> 8), .b = @truncate(n) };
    }
};
```

## Zig types and their JSON

| Zig | JSON |
| --- | --- |
| `bool`, integers, floats | `true`, `false`, numbers |
| `?T` | `null`, or the `T` |
| enums, enum literals | the member's name: `"hard"` (a number reads too) |
| `[]const u8`, string literals, `[*:0]const u8`, `[N:0]u8` | a string |
| slices, arrays, vectors, tuples | an array - `[N]u8` and `&[_]u8{...}` included, for colours and hashes |
| structs | an object, fields in the order they are declared |
| tagged unions | `{"arm": payload}`, or `"arm"` alone when it holds nothing |
| `std.ArrayList(T)` | an array |
| `std.StringHashMap(V)`, `std.StringArrayHashMapUnmanaged(V)` | an object; a hash map is written sorted, having no order of its own |
| `*T` | whatever `T` is |
| `json.Value`, `json.Document`, `json.Parsed(T)` | what they hold |

## One token at a time

`Reader` hands out tokens - `.object_begin`, `.key`, `.string`, `.number`,
and so on - from text, from CBOR or from a `Value`, and `Writer` takes them
back, as text or as CBOR. They are what everything above is made of, and
what to reach for when a file is a stream of records, or a converter wants
to see every token:

```zig
var reader: json.Reader = .init(gpa, text, .{});
defer reader.deinit();
while (try reader.next()) |token| switch (token) {
    .key => |name| ...,
    .number => |n| total += n.asFloat(f64),
    else => {},
};
```

A number stays as its text until it is asked for as a type, so
`n.asInt(u64)` of `18446744073709551615` is exact. `peek` looks at the next
token without taking it, and `skipValue` passes over a whole value however
deep. The writer checks, in debug builds, that it is given well-formed JSON:
a value without a key inside an object is an assertion, not a broken file.

## Speed

Timed against `std.json` with `zig build bench` (ReleaseFast, Windows,
best of seven, three runs), on three documents shaped like game data: a tile
map with four 256×256 layers of numbers, twenty thousand records of strings
and small objects, and a string table of twenty thousand keys.

| | fluxion-json against std.json |
| --- | --- |
| tile map: parse to a tree | 2.6 - 3.0 times as fast |
| records: parse to a tree | 1.3 - 1.4 times as fast |
| string table: parse, look up every key | 1.6 - 2.1 times as fast |
| parse into structs | about the same: 0.96 - 1.15 |
| write compact | the same to 1.3 times as fast |
| write indented, tile map | the same to 1.4 times as fast |
| write indented, records | 0.8 - 0.9 of the speed |

Strings are scanned sixteen bytes at a time, and a reader's hot path knows
the grammar and nothing else: every error message is worked out afterwards,
from the text, by code that only runs when something is wrong. The one case
that is slower is the one doing more work - `std.json` gives every item of an
indented object a line, and this lays each object out to see whether it fits
on one.

The same three documents as CBOR, against themselves as JSON text:

| | CBOR against JSON text |
| --- | --- |
| size: tile map, records, string table | 57%, 82% and 90% of the bytes |
| write | 1.5 - 1.6 times as fast |
| read, tile map | 1.05 - 1.2 times as fast |
| read, records and string table | about the same: 0.85 - 1.02 |

Reading gains less than the size suggests because a `Number` token is text,
whatever it was read from: a number in CBOR is written out as digits, and
read back from them when it is asked for as a type.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-json
```

Or, for a checkout next to your project, add to `build.zig.zon`:

```zig
.dependencies = .{
    .fluxion_json = .{ .path = "../fluxion-json" },
},
```

Either way, wire it up in `build.zig`:

```zig
const fluxion_json = b.dependency("fluxion_json", .{ .target = target, .optimize = optimize });
exe_mod.addImport("fluxion_json", fluxion_json.module("fluxion_json"));
```

It depends on nothing but the standard library, and builds for
`wasm32-freestanding` as well, which the test suite checks.

## Build

```bash
zig build test        # the test suite, and a browser build of the library
zig build example     # a tour: read, change, lay out, save, load, merge, and mistakes
zig build bench       # the timings above
zig build docs        # API documentation into zig-out/docs
```

## The tests

The suite reads what JSONTestSuite says every reader must accept and refuse,
and checks each refusal says where. Four hundred random trees are written in
seven layouts and read back equal, and every container in the output is
checked against the layout's promise - on one line only if it fits, over
several only if it would not - from the text itself rather than from the
writer's own sums. Twenty thousand damaged documents are read in all three
syntaxes without a crash, random trees are read by `std.json` too and must
come out the same, and every allocation that can fail is made to fail in
turn, leaking nothing.

CBOR is held to RFC 8949's own examples, each read as the JSON it stands for
or refused where JSON has no room for it. Four hundred random trees go
through CBOR and must come back equal, convert to the same text as the tree
written straight out, and convert back to the same bytes. Twenty thousand
damaged CBOR documents are read without a crash, and `valid` must agree
with `parse` about every one.

## Where it sits

The first tier of the Fluxion licence ladder: `CC0-1.0`, and no dependencies.
JSON is the format other programs speak - level editors, tile editors, web
services - so the code that reads it should cost nobody anything to use, or
to copy a function out of.

## Licence

`SPDX-License-Identifier: CC0-1.0`

[CC0 1.0 Universal](LICENSE): a public domain dedication. Do whatever you
like with this, no attribution required.
