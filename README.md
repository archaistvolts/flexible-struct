# flexible-struct

A single buffer layout library for structs with flexible fields.

# About

User defined `Layout` fields are first in memory with order determined by Zig.
Flexible fields are second and sorted by descending alignment. This allows
offsets to be calculated with a SIMD prefix sum instead of an inline loop (see
`calcOffsets()`).

# Features

1. Support any struct: auto, extern or packed.
1. Constant time field access.
1. APIs: Layout, Self and bytes.  Users can ptrCast between them.
1. Computed fields.
1. LSP cooperation. Avoid created/refified types which break autocomplete.


## Docs

https://archaistvolts.github.io/flexible-struct

## Usage

Add a `pub const flexible_array_capacities` decl to your `Layout` which maps
flexible array fields to their capacities.

```zig
const Layout = struct {
        capacity: u8,
        flexible: [*]u8 = undefined,
        computed: [*]u8 = undefined,

        pub const flexible_array_capacities = .{
            .flexible = .capacity,
            .computed = .computedLen,
        };

        pub fn computedLen(_: *const @This()) usize {
            return 68;
        }
    };

    const Model = Struct(Layout, .{});
    const initlayout = Layout{ .capacity = 42 };
    var buf: Model.Buf(&initlayout) align(Model.ALIGN) = undefined; // buffer must be aligned
    const model = try Model.initBuffer(&buf, &initlayout);
    try testing.expectEqual(42, model.value(.capacity));
    try testing.expectEqual(42, model.slice(.flexible).len);
    try testing.expectEqual(42, model.asLayout().capacity); // Self <-> Layout
    try testing.expectEqual(42, Model.fromLayout(model.asLayout()).value(.capacity));
    try testing.expectEqual(68, model.slice(.computed).len);
    try testing.expectEqual(136, model.sizeInBytes()); // 24+42+68(~8)=134(~8)=136
}
```

More tests toward bottom of [src/flexible-struct.zig](src/flexible-struct.zig).

## Acknowledgments
- https://tristanpemble.com/resizable-structs-in-zig
- https://github.com/tristanpemble/resizable-struct
- https://codeberg.org/ziglang/zig/pulls/30823

## License

MIT

## Contributing

Human contributions very welcome!
