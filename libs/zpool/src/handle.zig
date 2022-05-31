const std = @import("std");

/// Returns a struct consisting of an array `index` and a semi-unique `cycle`,
/// which exists to distinguish handles with the same array `index`.
///
/// The `cycle` value is only unique within the incremental period of an
/// unsigned integer with `cycle_bits`, so a larger number of `cycle_bits`
/// provides a larger scope of identifiable conflicts between handles for the
/// same `index`.
///
/// `Handle` is generic because while the `{ index, cycle }` pattern is widely
/// applicable, a good distribution of bits between `index` and `cycle` and the
/// overall size of a handle are highly dependent on the lifecycle of the
/// resource being identified by a handle and the systems consuming handles.
///
/// Reasonable values for `index_bits` depend on the maximum number of
/// uniquely identifiable resources your API will to identify with handles.
/// Generally this is directly tied to the length of the array(s) in which
/// you will store data to be referenced by a handle's `index`.
///
/// Reasonable values for `cycle_bits` depend on the frequency with which your
/// API expects to be issuing handles, and how many cycles of your application
/// are likely to elapse before an expired handle will likely no longer be
/// retained by the API caller's data structures.
///
/// For example, a `Handle(16, 16)` may be sufficient for a GPU resource like
/// a texture or buffer, where 64k instances of that resource is a reasonable
/// upper bound.
///
/// A `Handle(22, 10)` may be more appropriate to identify an entity in a
/// system where we can safely assume that 4 million entities, is a lot, and
/// that API callers can discover and discard expired entity handles within
/// 1024 frames of an entity being destroyed and its handle's `index` being
/// reissued for use by a distinct entity.
///
/// `TResource` identifies type of resource referenced by a handle, and
/// provides a type-safe distinction between two otherwise equivalently
/// configured `Handle` types, such as:
/// * `const BufferHandle  = Handle(16, 16, Buffer);`
/// * `const TextureHandle = Handle(16, 16, Texture);`
///
/// The total size of a handle will always be the size of an addressable
/// unsigned integer of type `u8`, `u16`, `u32`, `u64`, `u128`, or `u256`.
pub fn Handle(
    comptime index_bits: u8,
    comptime cycle_bits: u8,
    comptime TResource: type,
) type {
    if (index_bits == 0) @compileError("index_bits must be greater than 0");
    if (cycle_bits == 0) @compileError("cycle_bits must be greater than 0");

    const id_bits: u16 = @as(u16, index_bits) + @as(u16, cycle_bits);
    const Id = switch (id_bits) {
        8 => u8,
        16 => u16,
        32 => u32,
        64 => u64,
        128 => u128,
        256 => u256,
        else => @compileError("index_bits + cycle_bits must sum to exactly " ++
            "8, 16, 32, 64, 128, or 256 bits"),
    };

    const utils = @import("utils.zig");
    const UInt = utils.UInt;
    const AddressableUInt = utils.AddressableUInt;

    return struct {
        const Self = @This();

        const CompactHandle = Self;
        const CompactIndex = UInt(index_bits);
        const CompactCycle = UInt(cycle_bits);
        const CompactUnion = extern union {
            id: Id,
            bits: packed struct {
                index: CompactIndex,
                cycle: CompactCycle,
            },
        };

        pub const Resource = TResource;

        pub const AddressableIndex = AddressableUInt(index_bits);
        pub const AddressableCycle = AddressableUInt(cycle_bits);

        pub const max_index = ~@as(CompactIndex, 0);
        pub const max_cycle = ~@as(CompactCycle, 0);
        pub const max_count = @as(Id, max_index - 1) + 2;

        id: Id = 0,

        pub const nil = Self{ .id = 0 };

        pub fn init(index: CompactIndex, cycle: CompactCycle) Self {
            var u = CompactUnion{ .bits = .{
                .index = index,
                .cycle = cycle,
            } };
            return .{ .id = u.id };
        }

        /// Unpacks the `index` and `cycle` bit fields that comprise
        /// `Handle.id` into an `AddressableHandle`, which stores
        /// the `index` and `cycle` values in pointer-addressable fields.
        pub fn addressable(self: Self) AddressableHandle {
            var u = CompactUnion{ .id = self.id };
            return .{
                .index = u.bits.index,
                .cycle = u.bits.cycle,
            };
        }

        /// When you want to directly access the `index` and `cycle` of a
        /// handle, first convert it to an `AddressableHandle` by calling
        /// `Handle.addressable()`.
        /// An `AddressableHandle` can be converted back into a "compact"
        /// `Handle` by calling `AddressableHandle.compact()`.
        pub const AddressableHandle = struct {
            index: AddressableIndex = 0,
            cycle: AddressableCycle = 0,

            /// Returns the corresponding `Handle`
            pub fn handle(self: AddressableHandle) CompactHandle {
                var u = CompactUnion{ .bits = .{
                    .index = @intCast(CompactIndex, self.index),
                    .cycle = @intCast(CompactCycle, self.cycle),
                } };
                return .{ .id = u.id };
            }
        };

        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            const n = @typeName(Resource);
            const a = self.addressable();
            return writer.print("{s}[{}#{}]", .{ n, a.index, a.cycle });
        }
    };
}

////////////////////////////////////////////////////////////////////////////////

test "Handle sizes and alignments" {
    const testing = std.testing;
    const expectEqual = testing.expectEqual;

    {
        const H = Handle(4, 4, void);
        try expectEqual(@sizeOf(u8), @sizeOf(H));
        try expectEqual(@alignOf(u8), @alignOf(H));
        try expectEqual(4, @bitSizeOf(H.CompactIndex));
        try expectEqual(4, @bitSizeOf(H.CompactCycle));
        try expectEqual(8, @bitSizeOf(H.AddressableIndex));
        try expectEqual(8, @bitSizeOf(H.AddressableCycle));

        const A = H.AddressableHandle;
        try expectEqual(@sizeOf(u16), @sizeOf(A));
        try expectEqual(@alignOf(u8), @alignOf(A));
    }

    {
        const H = Handle(6, 2, void);
        try expectEqual(@sizeOf(u8), @sizeOf(H));
        try expectEqual(@alignOf(u8), @alignOf(H));
        try expectEqual(6, @bitSizeOf(H.CompactIndex));
        try expectEqual(2, @bitSizeOf(H.CompactCycle));
        try expectEqual(8, @bitSizeOf(H.AddressableIndex));
        try expectEqual(8, @bitSizeOf(H.AddressableCycle));

        const A = H.AddressableHandle;
        try expectEqual(@sizeOf(u16), @sizeOf(A));
        try expectEqual(@alignOf(u8), @alignOf(A));
    }

    {
        const H = Handle(8, 8, void);
        try expectEqual(@sizeOf(u16), @sizeOf(H));
        try expectEqual(@alignOf(u16), @alignOf(H));
        try expectEqual(8, @bitSizeOf(H.CompactIndex));
        try expectEqual(8, @bitSizeOf(H.CompactCycle));
        try expectEqual(8, @bitSizeOf(H.AddressableIndex));
        try expectEqual(8, @bitSizeOf(H.AddressableCycle));

        const A = H.AddressableHandle;
        try expectEqual(@sizeOf(u16), @sizeOf(A));
        try expectEqual(@alignOf(u8), @alignOf(A));
    }

    {
        const H = Handle(12, 4, void);
        try expectEqual(@sizeOf(u16), @sizeOf(H));
        try expectEqual(@alignOf(u16), @alignOf(H));
        try expectEqual(12, @bitSizeOf(H.CompactIndex));
        try expectEqual(4, @bitSizeOf(H.CompactCycle));
        try expectEqual(16, @bitSizeOf(H.AddressableIndex));
        try expectEqual(8, @bitSizeOf(H.AddressableCycle));

        const A = H.AddressableHandle;
        try expectEqual(@sizeOf(u32), @sizeOf(A));
        try expectEqual(@alignOf(u16), @alignOf(A));
    }

    {
        const H = Handle(16, 16, void);
        try expectEqual(@sizeOf(u32), @sizeOf(H));
        try expectEqual(@alignOf(u32), @alignOf(H));
        try expectEqual(16, @bitSizeOf(H.CompactIndex));
        try expectEqual(16, @bitSizeOf(H.CompactCycle));
        try expectEqual(16, @bitSizeOf(H.AddressableIndex));
        try expectEqual(16, @bitSizeOf(H.AddressableCycle));

        const A = H.AddressableHandle;
        try expectEqual(@sizeOf(u32), @sizeOf(A));
        try expectEqual(@alignOf(u16), @alignOf(A));
    }

    {
        const H = Handle(22, 10, void);
        try expectEqual(@sizeOf(u32), @sizeOf(H));
        try expectEqual(@alignOf(u32), @alignOf(H));
        try expectEqual(22, @bitSizeOf(H.CompactIndex));
        try expectEqual(10, @bitSizeOf(H.CompactCycle));
        try expectEqual(32, @bitSizeOf(H.AddressableIndex));
        try expectEqual(16, @bitSizeOf(H.AddressableCycle));

        const A = H.AddressableHandle;
        try expectEqual(@sizeOf(u64), @sizeOf(A));
        try expectEqual(@alignOf(u32), @alignOf(A));
    }
}

////////////////////////////////////////////////////////////////////////////////

test "Handle.format()" {
    const bufPrint = std.fmt.bufPrint;
    const expectEqualStrings = std.testing.expectEqualStrings;

    const Foo = struct {};
    const H = Handle(12, 4, Foo);
    const h = H.init(0, 1);

    var buffer = [_]u8{0} ** 128;
    const s = try bufPrint(buffer[0..], "{}", .{h});
    try expectEqualStrings("Foo[0#1]", s);
}
