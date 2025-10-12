const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_pixels = 400_000_000;
pub const encoding_epilogue = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };
pub const signature = [4]u8{ 'q', 'o', 'i', 'f' };
pub const magic_number = 0x716f6966;

pub const DecodeError = error{ InvalidQoi, ImageTooLarge, OutOfMemory, InvalidEncoding };
pub const EncodeError = error{ EmptyPixelBuffer, ZeroPixelCount, ImageTooLarge, OutOfMemory };

/// Holds image pixel and meta data.
/// `pixels` stores pixels top to bottom, left to right
pub const Image = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    channels: Channel,
    colorspace: Colorspace = .srgb,

    pub fn deinit(self: Image, gpa: Allocator) void {
        gpa.free(self.pixels);
    }
};

pub const Channel = enum(u8) {
    rgb = 3,
    rgba = 4,
};

pub const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

/// QOI header info
pub const Desc = struct {
    const size = 14;
    width: u32,
    height: u32,
    channels: Channel,
    colorspace: Colorspace,

    pub fn decode(data: []const u8) DecodeError!Desc {
        if (data.len < size) return error.InvalidQoi;
        if (std.mem.readInt(u32, data[0..4], .big) != magic_number) return error.InvalidQoi;

        const width = std.mem.readInt(u32, data[4..8], .big);
        const height = std.mem.readInt(u32, data[8..12], .big);
        const channels = data[12];
        const colorspace = data[13];

        if (width == 0 or height == 0) return error.InvalidQoi;

        return .{
            .width = width,
            .height = height,
            .channels = std.enums.fromInt(Channel, channels) orelse return error.InvalidQoi,
            .colorspace = std.enums.fromInt(Colorspace, colorspace) orelse return error.InvalidQoi,
        };
    }
};

const Encoding = struct {
    pub const index: u8 = 0x00;
    pub const diff: u8 = 0x40;
    pub const luma: u8 = 0x80;
    pub const run: u8 = 0xc0;
    pub const rgb: u8 = 0xfe;
    pub const rgba: u8 = 0xff;
};

const Pixel = packed struct(u32) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub fn hash(self: Pixel) u8 {
        return @truncate((@as(u16, self.r) * 3 + @as(u16, self.g) * 5 + @as(u16, self.b) * 7 + @as(u16, self.a) * 11) % 64);
    }
};

/// Does a few quick checks on `data` to determine if it holds a qoi image.
///
/// It tries to parse a `Desc` from `data` and checks if `data` can hold
/// the minimal encoded image.
pub fn isQoi(data: []const u8) bool {
    if (data.len < Desc.size + 1 + encoding_epilogue.len) return false;
    _ = Desc.decode(data) catch return false;
    return true;
}

/// Encodes `pixels` into QOI format if it is non-empty and `desc` describes
/// a valid image.
///
/// Note: Encodes a QOI description header before the QOI encoding ops.
/// 
/// Caller owns returned memory.
pub fn encode(gpa: Allocator, pixels: []const u8, desc: Desc) EncodeError![]u8 {
    const pixel_count = desc.height * desc.width;

    if (pixels.len == 0) return error.EmptyPixelBuffer;
    if (pixel_count == 0) return error.ZeroPixelCount;
    if (pixel_count >= max_pixels) return error.ImageTooLarge;

    const channels = @intFromEnum(desc.channels);
    // based on the worstcase of every pixel being encoded individually
    // along with an rbg(a) tag byte
    const max_size = pixel_count * (channels + 1) + Desc.size + encoding_epilogue.len;

    // todo: don't preallocate so much extra
    var bytes_list: std.ArrayList(u8) = try .initCapacity(gpa, max_size);
    var bytes = bytes_list.allocatedSlice();

    std.mem.writeInt(u32, bytes[0..4], magic_number, .big);
    std.mem.writeInt(u32, bytes[4..8], desc.width, .big);
    std.mem.writeInt(u32, bytes[8..12], desc.height, .big);
    bytes[12] = channels;
    bytes[13] = @intFromEnum(desc.colorspace);

    var write_offset: u32 = Desc.size;

    const pixel_len = pixel_count * channels;
    const pixel_end = pixel_len - channels;

    var index: [64]Pixel = .{Pixel{ .a = 0 }} ** 64;
    var prev_pixel = Pixel{};
    var curr_pixel = Pixel{};
    var run_len: u8 = 0;

    var pixel_offset: u32 = 0;
    while (pixel_offset < pixel_len) : (pixel_offset += channels) {
        curr_pixel.r = pixels[pixel_offset];
        curr_pixel.g = pixels[pixel_offset + 1];
        curr_pixel.b = pixels[pixel_offset + 2];
        if (desc.channels == .rgba)
            curr_pixel.a = pixels[pixel_offset + 3];

        // continue an active run
        if (curr_pixel == prev_pixel) {
            run_len += 1;
            if (run_len == 62 or pixel_offset == pixel_end) {
                bytes[write_offset] = Encoding.run | (run_len - 1);
                write_offset += 1;
                run_len = 0;
            }
        } else {
            var index_pos: u8 = 0;

            // finish an active run
            if (run_len > 0) {
                bytes[write_offset] = Encoding.run | (run_len - 1);
                write_offset += 1;
                run_len = 0;
            }

            index_pos = curr_pixel.hash();

            // save an index
            if (index[index_pos] == curr_pixel) {
                bytes[write_offset] = Encoding.index | index_pos;
                write_offset += 1;
            } else {
                index[index_pos] = curr_pixel;

                if (curr_pixel.a == prev_pixel.a) {
                    const r_diff = curr_pixel.r -% prev_pixel.r;
                    const g_diff = curr_pixel.g -% prev_pixel.g;
                    const b_diff = curr_pixel.b -% prev_pixel.b;

                    const rg_diff = r_diff -% g_diff;
                    const bg_diff = b_diff -% g_diff;

                    // small diff
                    // -3 < diff < 2
                    if (r_diff > 253 and r_diff < 2 and
                        g_diff > 253 and g_diff < 2 and
                        b_diff > 253 and b_diff < 2)
                    {
                        const r_diff2 = (r_diff +% 2) << 4;
                        const g_diff2 = (g_diff +% 2) << 2;
                        const b_diff2 = b_diff +% 2;
                        bytes[write_offset] = Encoding.diff | r_diff2 | g_diff2 | b_diff2;
                        write_offset += 1;

                        // luminance diff
                        // -9 < rb_diff < 8
                        // -33 < g_diff < 32
                    } else if (rg_diff > 247 and rg_diff < 8 and
                        g_diff > 223 and g_diff < 32 and
                        bg_diff > 247 and bg_diff < 8)
                    {
                        const g_diff2 = g_diff +% 32;
                        const rg_diff2 = (rg_diff +% 8) << 4;
                        const bg_diff2 = (bg_diff +% 8);
                        bytes[write_offset] = Encoding.luma | g_diff2;
                        bytes[write_offset + 1] = rg_diff2 | bg_diff2;
                        write_offset += 2;

                        // store single rgb pixel
                    } else {
                        bytes[write_offset] = Encoding.rgb;
                        bytes[write_offset + 1] = curr_pixel.r;
                        bytes[write_offset + 2] = curr_pixel.g;
                        bytes[write_offset + 3] = curr_pixel.b;
                        write_offset += 4;
                    }

                    // store single rgba pixel
                } else {
                    bytes[write_offset] = Encoding.rgba;
                    bytes[write_offset + 1] = curr_pixel.r;
                    bytes[write_offset + 2] = curr_pixel.g;
                    bytes[write_offset + 3] = curr_pixel.b;
                    bytes[write_offset + 4] = curr_pixel.a;
                    write_offset += 5;
                }
            }
        }

        prev_pixel = curr_pixel;
    }

    @memcpy(bytes[write_offset .. write_offset + 8], &encoding_epilogue);
    write_offset += 8;

    bytes_list.items = bytes[0..write_offset];
    // bytes_list.shrinkAndFree(gpa, write_offset);

    return try bytes_list.toOwnedSlice(gpa);
}

fn debug(tag: u8, off: u32, px: Pixel) void {
    const name = switch (tag) {
        Encoding.index => "INDEX",
        Encoding.diff => "DIFF",
        Encoding.luma => "LUMA",
        Encoding.run => "RUN",
        Encoding.rgb => "RGB",
        Encoding.rgba => "RGBA",
        else => unreachable,
    };

    std.debug.print("{x} {s} px: 0x{x}\n", .{ off, name, @as(u32, @bitCast(px)) });
}

/// Decodes the QOI encoded data in `data`.
/// Assumes data begins with a QOI description header.
pub fn decode(gpa: Allocator, data: []const u8) DecodeError!Image {
    var read_offset: u32 = 14;
    const desc = try Desc.decode(data);

    const pixel_count = desc.width * desc.height;
    if (pixel_count > max_pixels) return error.ImageTooLarge;

    const channels = @intFromEnum(desc.channels);
    const byte_len = pixel_count * channels;
    var pixels = try gpa.alloc(u8, byte_len);
    errdefer gpa.free(pixels);

    var index: [64]Pixel = .{Pixel{ .a = 0 }} ** 64;
    var prev_pixel = Pixel{};
    const chunks_len = data.len - encoding_epilogue.len;
    var run_len: u8 = 0;

    var pixel_offset: u32 = 0;
    while (pixel_offset < byte_len) : (pixel_offset += channels) {
        if (run_len > 0) {
            run_len -= 1;
        } else if (read_offset < chunks_len) {
            const tag = data[read_offset];
            read_offset += 1;
            switch (tag) {
                Encoding.rgb => {
                    prev_pixel.r = data[read_offset];
                    prev_pixel.g = data[read_offset + 1];
                    prev_pixel.b = data[read_offset + 2];
                    read_offset += 3;
                },
                Encoding.rgba => {
                    prev_pixel.r = data[read_offset];
                    prev_pixel.g = data[read_offset + 1];
                    prev_pixel.b = data[read_offset + 2];
                    prev_pixel.a = data[read_offset + 3];
                    read_offset += 4;
                },
                else => switch (tag & 0xc0) {
                    Encoding.index => {
                        prev_pixel = index[tag];
                    },
                    Encoding.diff => {
                        prev_pixel.r +%= ((tag >> 4) & 0x03) -% 2;
                        prev_pixel.g +%= ((tag >> 2) & 0x03) -% 2;
                        prev_pixel.b +%= (tag & 0x03) -% 2;
                    },
                    Encoding.luma => {
                        const b = data[read_offset];
                        read_offset += 1;
                        const green_diff = (tag & 0x3f) -% 32;
                        prev_pixel.r +%= green_diff -% 8 +% ((b >> 4) & 0x0f);
                        prev_pixel.g +%= green_diff;
                        prev_pixel.b +%= green_diff -% 8 +% (b & 0x0f);
                    },
                    Encoding.run => {
                        run_len = tag & 0x3f;
                    },
                    else => return error.InvalidEncoding,
                },
            }

            index[prev_pixel.hash()] = prev_pixel;
        }

        pixels[pixel_offset] = prev_pixel.r;
        pixels[pixel_offset + 1] = prev_pixel.g;
        pixels[pixel_offset + 2] = prev_pixel.b;
        if (desc.channels == .rgba)
            pixels[pixel_offset + 3] = prev_pixel.a;
    }

    return .{
        .pixels = pixels,
        .width = desc.width,
        .height = desc.height,
        .channels = desc.channels,
        .colorspace = desc.colorspace,
    };
}

test "Pixel hashing" {
    var black = Pixel{};
    var magenta = Pixel{ .r = 255, .b = 255 };
    try std.testing.expectEqual(53, black.hash());
    try std.testing.expectEqual(43, magenta.hash());
}
