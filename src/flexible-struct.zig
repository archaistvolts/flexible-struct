//! # About
//!
//! A single buffer layout library for structs with flexible fields. User
//! defined `Layout` fields are first in memory with order determined by Zig.
//! Flexible fields are second and sorted by descending alignment. With no
//! padding, flexible offsets can be calculated in constant time (see
//! `calcOffsets()`).
//!
//! # Features
//!
//! 1. Support all structs: auto, extern, packed
//! 1. Constant time field access.
//! 1. APIs: Layout, Self and bytes.  Users can ptrCast between them.
//! 1. Computed fields.
//! 1. LSP cooperation. Avoid created/reified types which break autocomplete.
//!
//! # Cached Layout API
//!
//! The core methods `calcOffsetsLayout` and `flexibleCapacities` accept a
//! Layout. Layouts are first class in addition to Self. Layout is user
//! specified and allows customization unlike reified `@Struct` types.
//!
//! # Tradeoff
//!
//! Possible padding after fixed fields (compared with
//! [resizable-struct](https://codeberg.org/ziglang/zig/pulls/30823) where all
//! fields are ordered with descending alignment) for constant time field
//! access.
//!
//! # Buffer layout
//! Given a user `Layout` (fixed fields), the buffer format is:
//!```
//! [ fixed fields | fixed padding | flexible fields | flexible padding ]
//! ^ ALIGN                        ^ FLEX_ALIGN                         ^ ALIGN
//!```
//!
//! # Use
//!
//! A Layout decl 'pub const flexible_array_capacities` maps flexible
//! fields to their cached or computed capacities.
//!
//! ```zig
//! ```
//!
//! # Prior Art - References
//!
//! 1. https://tristanpemble.com/resizable-structs-in-zig/
//! 2. https://codeberg.org/ziglang/zig/pulls/30823
//!
//! # TODOS - IDEAS
//!
//! - Options
//!   - user overrides for methods such as calcOffsets.
//! - reduce binary footprint
//!     - remove inline loops and comptime params.
//! - de/serialization helpers.
//! - when fixed padding is large enough for a 'buffer_capacity' Size, add a
//!   managed API with resize, resizeAssumeCapacity, resizeBounded and a hidden
//!   field helper.

pub const Options = struct {
    /// size used for offset calculations and methods such as `sizeInBytes`.
    /// smaller types may be used for smaller address spaces and may be faster.
    Size: type = usize,
};

pub fn Struct(LayoutT: type, options: Options) type {
    return struct {
        /// this aligns Self pointers so we can omit 'align' pointer attributes.
        _: void align(ALIGN),

        pub const Layout = LayoutT;
        pub const Field = meta.FieldEnum(Layout);
        pub const Size = options.Size;
        const Decl = meta.DeclEnum(Layout);
        const fields_decls = meta.fieldNames(Field) ++ meta.fieldNames(Decl);
        const FieldOrDeclInt = @Int(
            .unsigned,
            math.ceilPowerOfTwo(usize, @max(8, fields_decls.len)) catch unreachable,
        );
        /// an enum of Layout field names followed by decl names.
        pub const FieldOrDecl = @Enum(FieldOrDeclInt, .exhaustive, fields_decls, &simd.iota(FieldOrDeclInt, fields_decls.len));
        const layout_struct = @typeInfo(Layout).@"struct";
        /// user map of flexible field names to Layout field or decl names.
        const flexible_array_capacities = if (@hasDecl(Layout, "flexible_array_capacities"))
            Layout.flexible_array_capacities
        else
            .{};

        /// field bitsets in unsorted Field order.
        const layout_field_sets = sets: {
            var flexibles = enums.EnumSet(Field).empty;
            var capacities = enums.EnumSet(Field).empty;
            for (@typeInfo(@TypeOf(flexible_array_capacities)).@"struct".field_names) |flexible_name| {
                if (!@hasField(Field, flexible_name))
                    @compileError("'" ++ flexible_name ++ "' is not a Layout field.");
                flexibles.insert(@field(Field, flexible_name));
                const capacity = @tagName(@field(flexible_array_capacities, flexible_name));
                if (@hasField(Layout, capacity) and @typeInfo(@FieldType(Layout, capacity)) == .int)
                    capacities.insert(@field(Field, capacity))
                else if (!@hasDecl(Layout, capacity))
                    @compileError("flexible_array_capacities missing Layout field or declaration: '" ++ flexible_name ++ "'");
            }
            break :sets .{ flexibles, capacities };
        };
        const flexible_field_set = layout_field_sets[0];
        const capacity_field_set = layout_field_sets[1];

        const layout_infos = blk: {
            var maxalign: mem.Alignment = .of(Layout);
            for (meta.tags(Field)) |field| {
                maxalign = maxalign.max(.fromByteUnits(AlignOf(field)));
            }
            var flexsizes: FlexSizes = undefined;
            var nextflexaligns: FlexSizes = undefined;
            for (0..NFLEX_FIELDS) |i| {
                nextflexaligns[i] = if (i < (NFLEX_FIELDS - 1))
                    AlignOf(flexible_field_ids[i + 1])
                else
                    1; // don't pad last field.  it must be done separately in calcOffsets.
                flexsizes[i] = @sizeOf(ElementOf(flexible_field_ids[i]));
            }

            break :blk .{ maxalign, flexsizes, nextflexaligns };
        };
        const alignment = layout_infos[0];
        const flex_field_sizes = layout_infos[1];
        /// `[2nd flexible field, ..., last flexible field, 1]`.
        ///
        /// first flexible align is statically known and omitted.
        const next_flexfield_aligns = layout_infos[2];
        const flex_alignmasks = next_flexfield_aligns - @as(FlexSizesV, @splat(1));
        const FLEX_ALIGN = if (flexible_fields_sorted.len > 0) AlignOf(flexible_fields_sorted[0]) else 1;

        pub const Capacities = @Struct(
            .@"extern",
            null,
            filterSlice(layout_struct.field_names, capacity_field_set),
            &@splat(Size),
            &@splat(.{}),
        );

        // # sorted fields section

        const Sort = struct {
            fn lessThanAlign(_: void, lhs: Field, rhs: Field) bool {
                return AlignOf(lhs) > AlignOf(rhs);
            }
        };
        /// sorted by alignment desc
        const flexible_fields_sorted: [NFIELDS]Field = fields: {
            if (NFIELDS == 0)
                break :fields .{};
            var fields = meta.tags(Field).*;
            mem.sort(Field, &fields, {}, Sort.lessThanAlign);
            break :fields fields;
        };
        const flexible_field_ids = ids: {
            var ids: []const Field = &.{};
            for (flexible_fields_sorted) |f| {
                if (isFlexibleArray(f))
                    ids = ids ++ .{f};
            }
            break :ids ids;
        };
        const capacity_field_ids = ids: {
            var ids: []const Field = &.{};
            for (flexible_field_ids) |field| {
                const capacity_fod = @field(flexible_array_capacities, @tagName(field));
                if (!isField(capacity_fod)) // skip computed fields
                    continue;
                const capacity = @field(Field, @tagName(capacity_fod));
                assert(capacity_field_set.contains(capacity));
                if (mem.indexOfScalar(Field, ids, capacity) == null)
                    ids = ids ++ .{capacity};
            }
            break :ids ids;
        };

        pub const ALIGN = alignment.toByteUnits();
        pub const NFIELDS = layout_struct.field_names.len;
        pub const NCAP_FIELDS = capacity_field_set.count();
        pub const NFLEX_FIELDS = flexible_field_set.count();
        pub const FIRST_FLEX_OFFSET = mem.alignForward(Size, @sizeOf(Layout), FLEX_ALIGN);

        const CapSizes = [NCAP_FIELDS]Size;
        const FlexSizes = [NFLEX_FIELDS]Size;
        const FlexSizesV = @Vector(NFLEX_FIELDS, Size);
        const Self = @This();

        /// flexible field capacities.
        pub fn flexibleCapacities(layout: *const Layout) FlexSizes {
            var capacities: FlexSizes = undefined;
            inline for (flexible_field_ids, &capacities) |flexible, *cap| {
                const capacity = @field(flexible_array_capacities, @tagName(flexible));
                cap.* = @intCast(if (comptime isField(capacity))
                    @field(layout, @tagName(capacity))
                else
                    @field(Layout, @tagName(capacity))(layout));
            }
            return capacities;
        }

        /// flexible field offsets.
        pub fn calcOffsetsFlexibleCapacities(capacities: *const FlexSizes) FlexSizes {
            const sizes = @as(FlexSizesV, capacities.*) * flex_field_sizes;
            const sizesaligned = (sizes + flex_alignmasks) & ~flex_alignmasks;
            var offsets: FlexSizes =
                @as(FlexSizesV, @splat(FIRST_FLEX_OFFSET)) +
                simd.prefixScan(.Add, 1, sizesaligned);
            if (NFLEX_FIELDS > 0)
                offsets[NFLEX_FIELDS - 1] = mem.alignForward(Size, offsets[NFLEX_FIELDS - 1], ALIGN);

            if (false and NFLEX_FIELDS > 0 and !@inComptime()) {
                std.debug.print(
                    \\
                    \\Layout fields     {any}
                    \\       size       {}
                    \\flex_field_sizes  {any}
                    \\next_field_aligns {any}
                    \\capacities        {any}
                    \\sizes             {any}
                    \\sizesaligned      {any}
                    \\offsets           {any}
                    \\ALIGN             {}
                    \\FIRST_FLEX_OFFSET {}
                    \\
                ,
                    .{ comptime meta.tags(Field), @sizeOf(Layout), flex_field_sizes, next_flexfield_aligns, capacities, sizes, sizesaligned, offsets, ALIGN, FIRST_FLEX_OFFSET },
                );
            }
            return offsets;
        }

        /// flexible field offsets.
        pub fn calcOffsetsLayout(layout: *const Layout) FlexSizes {
            return calcOffsetsFlexibleCapacities(&flexibleCapacities(layout));
        }

        /// flexible field offsets.
        pub fn calcOffsets(self: *const Self) FlexSizes {
            return calcOffsetsLayout(self.asLayout());
        }

        /// change layout capacities. when mode is capacities_and_flexibles,
        /// adjust flexible field offsets accordingly.
        pub fn initCapacitiesPinned(
            capacities: *const Capacities,
            out: *Layout,
            comptime mode: enum { capacities, capacities_and_flexibles },
        ) void {
            inline for (capacity_field_ids) |field| {
                @field(out, @tagName(field)) = @intCast(@field(capacities, @tagName(field)));
            }
            if (mode == .capacities_and_flexibles)
                writeFlexibleOffsets(@ptrCast(out), &calcOffsetsLayout(out));
        }

        /// a Layout with given capacities and all other fields undefined.
        pub fn initCapacities(capacities: *const Capacities) Layout {
            var ret: Layout = undefined;
            initCapacitiesPinned(capacities, &ret, .capacities);
            return ret;
        }

        /// size in bytes of layout. assumes layout capacities are initialized
        /// along with any other fields needed by computed methods.
        pub fn sizeInBytesLayout(layout: *const Layout) Size {
            return if (NFLEX_FIELDS > 0)
                calcOffsetsLayout(layout)[NFLEX_FIELDS - 1] // TODO use layout instead of calculating. return alignFwd(lastfieldstart-start+lastfieldsize, ALIGN)
            else
                FIRST_FLEX_OFFSET;
        }

        pub fn sizeInBytes(self: *const Self) Size {
            return sizeInBytesLayout(self.asLayout());
        }

        pub fn sizeInBytesCapacities(capacities: *const Capacities) Size {
            return sizeInBytesLayout(&initCapacities(capacities));
        }

        /// a buffer with size determined by layout for use with initBuffer().
        pub fn Buf(comptime layout: *const Layout) type {
            return [sizeInBytesLayout(layout)]u8;
        }

        /// a buffer with size determined by capacities for use with initBuffer().
        pub fn BufCapacities(comptime capacities: *const Capacities) type {
            return Buf(&initCapacities(capacities));
        }

        ///
        pub fn writeFlexibleOffsets(buf: [*]align(ALIGN) u8, offs: *const FlexSizes) void {
            const layoutm = fromBytesMut(buf);
            const layout = layoutm.asLayoutMut();
            assert(@intFromPtr(buf) == @intFromPtr(layout));
            const nextoffs = simd.shiftElementsRight(offs.*, 1, FIRST_FLEX_OFFSET);
            inline for (flexible_field_ids, nextoffs) |flexible, nextoff| {
                const flexname = @tagName(flexible);
                const flexptr = &@field(layout, flexname);
                flexptr.* = @ptrCast(@alignCast(buf + @as(usize, @intCast(nextoff))));
                if (meta.sentinel(@FieldType(Layout, flexname))) |sentinel| { // set sentinel
                    const capacity = @field(flexible_array_capacities, flexname);
                    const capname = @tagName(capacity);
                    const len = if (@hasDecl(Layout, capname))
                        @field(Layout, capname)(layout) // computed call
                    else
                        @field(layout, capname);
                    flexptr.*[len] = sentinel;
                }
            }
        }

        /// a copy of layout backed by buf and with flexible fields
        /// pointing into buf.
        pub fn initBuffer(buf: []align(ALIGN) u8, layout: *const Layout) mem.Allocator.Error!*Self {
            const ret = mem.bytesAsValue(Layout, buf);
            ret.* = layout.*;
            if (NFLEX_FIELDS == 0)
                return @ptrCast(ret);
            const offs = calcOffsetsLayout(layout);
            if (offs[offs.len - 1] > buf.len)
                return error.OutOfMemory;
            writeFlexibleOffsets(buf.ptr, &offs);
            return @ptrCast(ret);
        }

        /// a struct with given capacities backed by buf and with flexible fields
        /// pointing into buf.
        pub fn initBufferCapacities(buf: []align(ALIGN) u8, capacities: *const Capacities) mem.Allocator.Error!*Self {
            return try initBuffer(buf, &initCapacities(capacities));
        }

        /// a Layout field or computed decl `capacity`.
        pub fn capacityOf(
            self: *const Self,
            comptime capacity: FieldOrDecl,
        ) CapacityOf(capacity) {
            const layout = self.asLayout();
            return if (@hasField(Field, @tagName(capacity)))
                @field(layout, @tagName(capacity))
            else
                @field(Layout, @tagName(capacity))(layout); // computed field call
        }

        /// unique capacity fields (no shared duplicates).
        pub fn loadCapacities(self: *const Self) CapSizes {
            const layout = self.asLayout();
            var capacities: CapSizes = undefined;
            inline for (capacity_field_ids, 0..) |field, j| {
                capacities[j] = @intCast(@field(layout, @tagName(field)));
            }
            return @bitCast(capacities);
        }

        /// one capacity per flexible field (possible shared duplicates).
        pub fn loadFlexibleCapacities(self: *const Self) FlexSizes {
            const layout = self.asLayout();
            var counts: FlexSizes = undefined;
            inline for (flexible_field_ids, 0..) |field, j| {
                counts[j] = @intCast(@field(layout, @tagName(flexibleCapacity(field))));
            }
            return @bitCast(counts);
        }

        pub fn create(allocator: mem.Allocator, capacities: *const Capacities) mem.Allocator.Error!*Self {
            const layout = initCapacities(capacities);
            const buf = try allocator.alignedAlloc(u8, alignment, sizeInBytesLayout(&layout));
            return try initBuffer(buf, &layout);
        }

        pub fn destroy(self: *const Self, allocator: mem.Allocator) void {
            allocator.free(self.asBytes()[0..self.sizeInBytes()]);
        }

        /// a Layout.<field> by value.
        pub fn value(self: *const Self, comptime field: Field) @FieldType(Layout, @tagName(field)) {
            return @field(self.asLayout(), @tagName(field));
        }

        /// a const pointer to Layout.<field>.
        pub fn ptr(self: *const Self, comptime field: Field) *const @FieldType(Layout, @tagName(field)) {
            return &@field(self.asLayout(), @tagName(field));
        }

        /// a mutable pointer to Layout.<field>.
        pub fn ptrMut(self: *Self, comptime field: Field) *@FieldType(Layout, @tagName(field)) {
            return @constCast(self.ptr(field));
        }

        /// a slice of Layout.<field> with the given len.
        pub fn sliceLen(self: *const Self, comptime field: Field, len: anytype) FieldSlice(field) {
            return @ptrCast(value(self, field)[0..@intCast(len)]);
        }

        /// a slice of Layout.<flexible> with its capacity field.
        pub fn slice(self: *const Self, comptime flexible: Field) FieldSlice(flexible) {
            return self.sliceCapacity(flexible, flexibleCapacity(flexible));
        }

        /// slice of Layout.<field> with given capacity field or decl. capacity
        /// is a Layout unsigned integer field or a method which returns one.
        pub fn sliceCapacity(
            self: *const Self,
            comptime field: Field,
            comptime capacity: FieldOrDecl,
        ) FieldSlice(field) {
            return self.sliceLen(field, self.capacityOf(capacity));
        }

        // Self <-> Layout <-> bytes helpers

        pub fn asLayout(self: *const Self) *align(ALIGN) const Layout {
            return @ptrCast(self);
        }

        pub fn asLayoutMut(self: *Self) *align(ALIGN) Layout {
            return @ptrCast(self);
        }

        pub fn fromLayout(layout: *align(ALIGN) const Layout) *const Self {
            return @ptrCast(layout);
        }

        pub fn fromLayoutMut(layout: *align(ALIGN) Layout) *Self {
            return @ptrCast(layout);
        }

        pub fn asBytes(self: *const Self) [*]align(ALIGN) const u8 {
            return @ptrCast(self);
        }

        pub fn asBytesMut(self: *Self) [*]align(ALIGN) u8 {
            return @ptrCast(self);
        }

        pub fn fromBytes(buf: [*]align(ALIGN) const u8) *const Self {
            return @ptrCast(buf);
        }

        pub fn fromBytesMut(buf: [*]align(ALIGN) u8) *Self {
            return @ptrCast(buf);
        }

        // Self <-> Layout <-> bytes helpers // end

        /// write field from src to dest. @memcopy or @memmove flexible fields
        /// depending on mode. write minimum length of dst and src.
        fn writeField(
            dst: *Self,
            src: *const Self,
            comptime field: Field,
            comptime mode: enum { copy, move },
        ) void {
            if (comptime flexible_field_set.contains(field)) {
                const d = dst.slice(field);
                const s = src.slice(field);
                const len = @min(d.len, s.len);
                if (mode == .copy)
                    @memcpy(d[0..len], s.ptr)
                else
                    @memmove(d[0..len], s.ptr);
            } else {
                @field(dst.asLayoutMut(), @tagName(field)) = @field(src.asLayout(), @tagName(field));
            }
        }

        /// copy field from src to dest. @memcpy flexible fields with minimum
        /// length of dst and src.
        pub fn copyField(dst: *Self, src: *const Self, comptime field: Field) void {
            return dst.writeField(src, field, .copy);
        }

        /// move field from src to dest. @memmove flexible fields with minimum
        /// length of dst and src.
        pub fn moveField(dst: *Self, src: *const Self, comptime field: Field) void {
            return dst.writeField(src, field, .move);
        }

        /// copy all fields from src to dest with `copyField`
        pub fn copy(dst: *Self, src: *const Self) void {
            inline for (comptime meta.tags(Field)) |field| {
                try dst.copyField(src, field);
            }
        }

        /// move all fields from src to dest with `moveField`
        pub fn move(dst: *Self, src: *const Self) void {
            inline for (comptime meta.tags(Field)) |field| {
                try dst.moveField(src, field);
            }
        }

        /// shrink capacities.  modify flexible pointers and move contents.
        ///
        /// asserts capacities are <= self capacities.
        pub fn shrinkCapacities(self: *Self, capacities: *const Capacities) void {
            const layout = self.asLayoutMut();
            const oldlayout align(ALIGN) = layout.*;

            inline for (capacity_field_ids) |capacity| {
                assert(@field(capacities, @tagName(capacity)) <= @field(oldlayout, @tagName(capacity)));
            }
            initCapacitiesPinned(capacities, layout, .capacities_and_flexibles);

            comptime var i = flexible_field_ids.len;
            inline while (i > 0) {
                i -= 1;
                const flexible = flexible_field_ids[i];
                self.moveField(fromLayout(&oldlayout), flexible);
            }
        }

        /// grow capacities.  modify flexible pointers and move contents.
        ///
        /// asserts capacities are >= self capacities.
        pub fn growCapacities(self: *Self, capacities: *const Capacities) void {
            const layout = self.asLayoutMut();
            const oldlayout align(ALIGN) = layout.*;

            inline for (capacity_field_ids) |capacity| {
                assert(@field(capacities, @tagName(capacity)) >= @field(oldlayout, @tagName(capacity)));
            }
            initCapacitiesPinned(capacities, layout, .capacities_and_flexibles);

            inline for (flexible_field_ids) |flexible| {
                self.moveField(fromLayout(&oldlayout), flexible);
            }
        }

        inline fn isFlexibleArray(field: Field) bool {
            return flexible_field_set.contains(field);
        }

        fn isField(field_or_decl: FieldOrDecl) bool {
            return @backingInt(field_or_decl) < NFIELDS;
        }

        fn AlignOf(field: Field) comptime_int {
            const fieldty = layout_struct.field_types[@backingInt(field)];
            if (isFlexibleArray(field)) {
                const pointer = @typeInfo(fieldty).pointer;
                return pointer.attrs.@"align" orelse @alignOf(pointer.child);
            }
            return @alignOf(fieldty);
        }

        fn ElementOf(comptime field: Field) type {
            const T = @FieldType(Layout, @tagName(field));
            return if (isFlexibleArray(field))
                meta.Elem(T)
            else
                T;
        }

        inline fn flexibleCapacity(comptime flexible: Field) FieldOrDecl {
            return @field(flexible_array_capacities, @tagName(flexible));
        }

        fn CapacityOf(comptime capacity: FieldOrDecl) type {
            return if (@hasField(Field, @tagName(capacity)))
                @FieldType(Layout, @tagName(capacity))
            else
                @typeInfo(@TypeOf(@field(Layout, @tagName(capacity)))).@"fn".return_type.?;
        }

        /// a Layout.<field> slice type
        fn FieldSlice(comptime field: Field) type {
            const T = @FieldType(Layout, @tagName(field));
            const pointer = @typeInfo(T).pointer;
            return @Pointer(.slice, pointer.attrs, pointer.child, pointer.sentinel());
        }
    };
}

fn mapFields(T: type, field: meta.FieldEnum(T), in: []const T) [in.len]@FieldType(T, @tagName(field)) {
    const F = @FieldType(T, @tagName(field));
    var out: [in.len]F = undefined;
    for (in, &out) |i, *o|
        o.* = @field(i, @tagName(field));
    return out;
}

fn filterSlice(src: anytype, set: anytype) []const meta.Elem(@TypeOf(src)) {
    var ret: []const meta.Elem(@TypeOf(src)) = &.{};
    for (src, 0..) |f, i| {
        if (set.contains(@fromBackingInt(i)))
            ret = ret ++ .{f};
    }
    return ret;
}

// TESTS

test Struct {
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
    try testing.expectEqual(136, model.sizeInBytes()); // (24+42+68)~8=134~8=136

    // change capacities then check last field (computed) has moved and retains values
    @memset(model.slice(.computed), 69);
    const computed1 = model.value(.computed);
    model.shrinkCapacities(&.{ .capacity = 36 }); // shrink and move
    try testing.expectEqual(128, model.sizeInBytes()); // (24+36+68)~8=128~8=128
    const computed2 = model.value(.computed);
    try testing.expectEqual(69, model.slice(.computed)[0]);
    try testing.expectEqual(69, model.slice(.computed)[35]);
    try testing.expectEqual(computed1 - 6, computed2);
    model.growCapacities(&.{ .capacity = 48 }); // grow and move
    try testing.expectEqual(144, model.sizeInBytes()); // (24+48+68)~8=140~8=144
    try testing.expectEqual(69, model.slice(.computed)[0]);
    try testing.expectEqual(69, model.slice(.computed)[35]);
    try testing.expectEqual(computed1 + 6, model.value(.computed));

    try testPacket(usize);
    try testPacket(u32);
    try testPacket(u16);
    try testPacket(u8);
}

fn testPacket(Size: type) !void {
    const host = "ziglang.org";
    try testing.expectEqual(11, host.len);

    const PacketLayout = struct { // @sizeOf(PacketLayout)=48, Packet{ALIGN=32,FLEX_ALIGN=32},
        buf_lens: u64,
        host_len: u32,
        write_buf: [*]align(32) u8, //  [48,84) | buf_lens=20 // flexible_start
        read_buf: [*]align(16) u8, //   [96,116)
        host: [*]u8, //                 [116,127) | host_len=11
        computed: [*]u8, //             [127,127+68=195) | computedLen=68
        // flexible_start               48 = alignForward(48, FLEX_ALIGN=32)
        // buffer_end                   224 = alignForward(195, ALIGN=32)

        /// map from capacity field or decl to flexible array field
        pub const flexible_array_capacities = .{
            .write_buf = .buf_lens,
            .read_buf = .buf_lens,
            .host = .host_len,
            .computed = .computedLen,
        };

        pub fn computedLen(_: *const @This()) u8 {
            return 68;
        }
    };

    const Packet = Struct(PacketLayout, .{ .Size = Size });
    try testing.expectEqual(48, @sizeOf(PacketLayout));
    try testing.expectEqual(64, mem.alignForward(Packet.Size, @sizeOf(PacketLayout), Packet.ALIGN));
    try testing.expectEqualSlices(Packet.Field, &.{ .write_buf, .read_buf, .host, .computed }, Packet.flexible_field_ids);
    try testing.expectEqualSlices(Packet.Field, &.{ .buf_lens, .host_len }, Packet.capacity_field_ids); // computed fields excluded
    try testing.expectEqualSlices(Packet.Size, &.{ 1, 1, 1, 1 }, &Packet.flex_field_sizes);
    try testing.expectEqualSlices(Packet.Size, &.{ 16, 1, 1, 1 }, &Packet.next_flexfield_aligns);

    const capacities: Packet.Capacities = .{ .buf_lens = 20, .host_len = host.len };
    try validateLayout(Packet, Packet.initCapacities(&capacities), &.{ 96, 116, 127, 224 });
    try testing.expectEqual(64, Packet.FIRST_FLEX_OFFSET);

    const packet = try Packet.create(testing.allocator, &capacities);
    defer packet.destroy(testing.allocator);
    const layout = packet.asLayout();
    try testing.expectEqual(capacities.buf_lens, layout.buf_lens);
    try testing.expectEqual(capacities.host_len, layout.host_len);

    @memcpy(packet.slice(.host), host);
    try testing.expectEqualSlices(u8, host, packet.slice(.host));
    try testing.expectEqual(layout.write_buf[0..@intCast(layout.buf_lens)], packet.slice(.write_buf));
    try testing.expectEqual(layout.read_buf[0..@intCast(layout.buf_lens)], packet.slice(.read_buf));
    try testing.expectEqual(layout.host[0..layout.host_len], packet.slice(.host));
    try testing.expectEqual(layout.computed[0..layout.computedLen()], packet.slice(.computed));
}

fn validateLayout(
    S: type,
    comptime layout: S.Layout,
    expected_offsets: *const S.FlexSizes,
) !void {
    var buf: S.Buf(&layout) align(S.ALIGN) = undefined;
    const self = try S.initBuffer(&buf, &layout);
    try testing.expectEqualSlices(S.Size, expected_offsets, &S.calcOffsetsLayout(&layout));
    inline for (S.flexible_field_ids) |flexiblefield| {
        @memset(self.slice(flexiblefield), @backingInt(flexiblefield));
    }
    inline for (S.flexible_field_ids) |flexiblefield| {
        const slice = self.slice(flexiblefield);
        try testing.expectEqual(@backingInt(flexiblefield), slice[0]);
        try testing.expectEqual(@backingInt(flexiblefield), slice[slice.len - 1]);
    }
    const lensv = self.loadCapacities();
    inline for (S.capacity_field_ids, 0..) |capfield, i| {
        try testing.expectEqual(lensv[i], @field(self.asLayout(), @tagName(capfield)));
    }
}

test "zero sized, missing flexible_array_capacities" {
    try validateLayout(Struct(struct {}, .{}), .{}, &.{});
    try validateLayout(Struct(struct {
        pub const flexible_array_capacities = .{};
    }, .{}), .{}, &.{});

    try validateLayout(Struct(struct {
        a: usize = 0,
        pub const flexible_array_capacities = .{};
    }, .{}), .{}, &.{});
    try validateLayout(Struct(struct {
        a: usize = 0,
    }, .{}), .{}, &.{});
}

test "misc layouts" {
    { // over aligned fixed field
        const L = struct {
            len: u32 align(32),
            flex: [*]u8, //        [32,43) | len=11
            //                     32
            //                     64=alignForward(43,32)
            pub const flexible_array_capacities = .{ .flex = .len };
        };
        const S = Struct(L, .{});
        try testing.expectEqual(32, S.ALIGN);
        try validateLayout(S, S.initCapacities(&.{ .len = 11 }), &.{64});
    }
    { // large fixed field
        const L = struct {
            b: u64,
            a: u8,
            data: [*]u8, // [24,35)
            //              24
            //              40=alignForward(35,8)
            pub const flexible_array_capacities = .{ .data = .a };
        };
        const S = Struct(L, .{});
        try validateLayout(S, S.initCapacities(&.{ .a = 11 }), &.{40});
        try testing.expectEqualSlices(S.Field, meta.tags(S.Field), &.{ .b, .a, .data });
    }
    { // single flexible align
        const L = struct {
            b: u64,
            a: u8,
            data: [*]align(16) u8, // [24,35)
            //              24
            //              48=alignForward(35,16)
            pub const flexible_array_capacities = .{ .data = .a };
        };
        const S = Struct(L, .{});
        try validateLayout(S, S.initCapacities(&.{ .a = 11 }), &.{48});
        try testing.expectEqualSlices(S.Field, meta.tags(S.Field), &.{ .b, .a, .data });
    }
    { // extern
        const L = extern struct {
            b: u64,
            a: u8,
            data: [*]align(16) u8, // [24,35)
            //              24
            //              48=alignForward(35,16)
            pub const flexible_array_capacities = .{ .data = .a };
        };
        const S = Struct(L, .{});
        try validateLayout(S, S.initCapacities(&.{ .a = 11 }), &.{48});
        try testing.expectEqualSlices(S.Field, meta.tags(S.Field), &.{ .b, .a, .data });
    }
}

test "sentinels" {
    const Ls = .{
        struct {
            len: u8,
            sentinelptr: [*:0]u8, //   [16,27)
            //                  16
            //                  32=alignForward(16+11=27, 8)
            pub const flexible_array_capacities = .{ .sentinelptr = .len };
        },
        struct { // computed sentinel
            sentinelptr: [*:0]u8, //   [8,19)
            //                  8
            //                  24=alignForward(19, 8)
            pub fn len(_: *const @This()) u8 {
                return 11;
            }
            pub const flexible_array_capacities = .{ .sentinelptr = .len };
        },
    };
    inline for (Ls) |L| {
        const S = Struct(L, .{});
        const is_computed = @hasDecl(L, "len");
        const s = try S.create(testing.allocator, &if (is_computed) .{} else .{ .len = 11 });
        defer s.destroy(testing.allocator);
        const layout = s.asLayout();
        try testing.expectEqual([*:0]u8, @TypeOf(layout.sentinelptr));
        const slice = if (is_computed)
            layout.sentinelptr[0..layout.len() :0]
        else
            layout.sentinelptr[0..layout.len :0];
        try testing.expectEqual(11, slice.len);
        try testing.expectEqual(0, slice[11]);
    }
}

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const meta = std.meta;
const simd = std.simd;
const math = std.math;
const assert = std.debug.assert;
const enums = std.enums;
const builtin = @import("builtin");
