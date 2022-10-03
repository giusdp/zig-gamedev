const std = @import("std");
const assert = std.debug.assert;

pub fn init(allocator: std.mem.Allocator) void {
    assert(mem_allocator == null);
    mem_allocator = allocator;
    mem_allocations = std.AutoHashMap(usize, usize).init(allocator);
}

pub fn deinit() void {
    assert(mem_allocator != null);
    assert(mem_allocations.?.count() == 0);
    mem_allocations.?.deinit();
    mem_allocations = null;
    mem_allocator = null;
}

pub fn Image(comptime ChannelType: type) type {
    return struct {
        const Self = @This();

        data: []ChannelType,
        width: u32,
        height: u32,
        bytes_per_row: u32,
        num_channels: u32,
        num_channels_in_file: u32,

        pub fn init(filename: [:0]const u8, forced_num_channels: u32) !Self {
            var x: c_int = undefined;
            var y: c_int = undefined;
            var ch: c_int = undefined;
            var data = switch (ChannelType) {
                u8 => stbi_load(filename, &x, &y, &ch, @intCast(c_int, forced_num_channels)),
                f16 => @ptrCast(?[*]f16, stbi_loadf(filename, &x, &y, &ch, @intCast(c_int, forced_num_channels))),
                f32 => stbi_loadf(filename, &x, &y, &ch, @intCast(c_int, forced_num_channels)),
                else => @compileError("[zstbi] ChannelType can be u8, f16 or f32."),
            };
            if (data == null)
                return error.StbiLoadFailed;

            const num_channels = if (forced_num_channels == 0) @intCast(u32, ch) else forced_num_channels;
            const width = @intCast(u32, x);
            const height = @intCast(u32, y);

            if (ChannelType == f16) {
                var data_f32 = @ptrCast([*]f32, data.?);
                const num = width * height * num_channels;
                var i: u32 = 0;
                while (i < num) : (i += 1) {
                    data.?[i] = @floatCast(f16, data_f32[i]);
                }
            }

            return Self{
                .data = data.?[0 .. width * height * num_channels],
                .width = width,
                .height = height,
                .bytes_per_row = width * num_channels * @sizeOf(ChannelType),
                .num_channels = num_channels,
                .num_channels_in_file = @intCast(u32, ch),
            };
        }

        pub fn deinit(image: *Self) void {
            stbi_image_free(image.data.ptr);
            image.* = undefined;
        }
    };
}

/// `pub fn setHdrToLdrScale(scale: f32) void`
pub const setHdrToLdrScale = stbi_hdr_to_ldr_scale;

/// `pub fn setHdrToLdrGamma(gamma: f32) void`
pub const setHdrToLdrGamma = stbi_hdr_to_ldr_gamma;

/// `pub fn setLdrToHdrScale(scale: f32) void`
pub const setLdrToHdrScale = stbi_ldr_to_hdr_scale;

/// `pub fn setLdrToHdrGamma(gamma: f32) void`
pub const setLdrToHdrGamma = stbi_ldr_to_hdr_gamma;

pub fn isHdr(filename: [:0]const u8) bool {
    return stbi_is_hdr(filename) == 1;
}

pub fn setFlipVerticallyOnLoad(should_flip: bool) void {
    stbi_set_flip_vertically_on_load(if (should_flip) 1 else 0);
}

var mem_allocator: ?std.mem.Allocator = null;
var mem_allocations: ?std.AutoHashMap(usize, usize) = null;
var mem_mutex: std.Thread.Mutex = .{};
const mem_alignment = 16;

export fn zstbiMalloc(size: usize) callconv(.C) ?*anyopaque {
    mem_mutex.lock();
    defer mem_mutex.unlock();

    const mem = mem_allocator.?.allocBytes(
        mem_alignment,
        size,
        0,
        @returnAddress(),
    ) catch @panic("zstbi: out of memory");

    mem_allocations.?.put(@ptrToInt(mem.ptr), size) catch @panic("zstbi: out of memory");

    return mem.ptr;
}

export fn zstbiRealloc(ptr: ?*anyopaque, size: usize) callconv(.C) ?*anyopaque {
    mem_mutex.lock();
    defer mem_mutex.unlock();

    const old_size = if (ptr != null) mem_allocations.?.get(@ptrToInt(ptr.?)).? else 0;
    const old_mem = if (old_size > 0)
        @ptrCast([*]u8, ptr)[0..old_size]
    else
        @as([*]u8, undefined)[0..0];

    const new_mem = mem_allocator.?.reallocBytes(
        old_mem,
        mem_alignment,
        size,
        mem_alignment,
        0,
        @returnAddress(),
    ) catch @panic("zstbi: out of memory");

    if (ptr != null) {
        const removed = mem_allocations.?.remove(@ptrToInt(ptr.?));
        std.debug.assert(removed);
    }

    mem_allocations.?.put(@ptrToInt(new_mem.ptr), size) catch @panic("zstbi: out of memory");

    return new_mem.ptr;
}

export fn zstbiFree(maybe_ptr: ?*anyopaque) callconv(.C) void {
    if (maybe_ptr) |ptr| {
        mem_mutex.lock();
        defer mem_mutex.unlock();

        const size = mem_allocations.?.fetchRemove(@ptrToInt(ptr)).?.value;
        const mem = @ptrCast(
            [*]align(mem_alignment) u8,
            @alignCast(mem_alignment, ptr),
        )[0..size];
        mem_allocator.?.free(mem);
    }
}

extern fn stbi_load(
    filename: [*:0]const u8,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]u8;

extern fn stbi_loadf(
    filename: [*:0]const u8,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]f32;

extern fn stbi_image_free(image_data: ?*anyopaque) void;

extern fn stbi_hdr_to_ldr_scale(scale: f32) void;
extern fn stbi_hdr_to_ldr_gamma(gamma: f32) void;
extern fn stbi_ldr_to_hdr_scale(scale: f32) void;
extern fn stbi_ldr_to_hdr_gamma(gamma: f32) void;

extern fn stbi_is_hdr(filename: [*:0]const u8) c_int;
extern fn stbi_set_flip_vertically_on_load(flag_true_if_should_flip: c_int) void;
