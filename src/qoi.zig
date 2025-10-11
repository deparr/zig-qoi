const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_pixels = 400_000_000;
pub const byte_stream_suffix = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

pub const Qoi = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    channels: Channel,
    colorspace: Colorspace,
};

pub const Channel = enum(u8) {
    rgb = 3,
    rgba = 4,
};

pub const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

const HeaderFull = packed struct {
    magic: u32,
    width: u32,
    height: u32,
    channels: u8,
    colorspace: u8,
};

pub const Header = packed struct {
    width: u32,
    height: u32,
    channels: u8,
    colorspace: u8,

    pub const signature = [4]u8{ 'q', 'o', 'i', 'f' };
    pub const magic = std.mem.readInt(u32, &signature, .big);

    pub fn decode(data: []const u8) !Header {
        if (data.len < @sizeOf(HeaderFull)) return error.TooSmall;
        if (std.mem.readInt(u32, data[0..4], .big) != Header.magic) return error.InvalidSignature;

        const width = std.mem.readInt(u32, data[4..8], .big);
        const height = std.mem.readInt(u32, data[8..12], .big);
        const channels = data[12];
        const colorspace = data[13];

        if (width == 0 or height == 0) return error.InvalidDimensions;
        if (channels < 3 or channels > 4) return error.InvalidChannels;
        if (colorspace > 1) return error.InvalidColorspace;

        return .{
            .width = width,
            .height = height,
            .channels = channels,
            .colorspace = colorspace,
        };
    }
};

pub const EncodeTag = union(enum) {
    run,
    prev,
    diff,
    index,
    luma,
    rgb,
    rgba,
};

pub const Pixel = packed struct(u32) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub fn hash(self: Pixel) u8 {
        return @truncate((@as(u16, self.r) * 3 + @as(u16, self.g) * 5 + @as(u16, self.b) * 7 + @as(u16, self.a) * 11) % 64);
    }
};

pub fn decode(gpa: Allocator, bytes: []const u8) !Qoi {
    const header = try Header.decode(bytes);
    const num_pixels = header.width * header.height;
    if (num_pixels > max_pixels) return error.ImageTooLarge;
    const byte_len = num_pixels * header.channels;
    var pixels = try gpa.alloc(u8, byte_len);
    errdefer gpa.free(pixels);

    var index: [64]Pixel = .{Pixel{ .a = 0 }} ** 64;
    var prev = Pixel{};
    const chunks_len = bytes.len - byte_stream_suffix.len;
    var idx: u32 = 14;
    var runs: u8 = 0;
    var px_idx: u32 = 0;
    while (px_idx < byte_len) : (px_idx += header.channels) {
        if (runs > 0) {
            runs -= 1;
        } else if (idx < chunks_len) {
            const tag_byte = bytes[idx];
            idx += 1;
            switch (tag_byte) {
                // QOI_OP_RGB
                0b1111_1110 => {
                    prev.r = bytes[idx];
                    prev.g = bytes[idx + 1];
                    prev.b = bytes[idx + 2];
                    idx += 3;
                },
                // QOI_OP_RGBA
                0b1111_1111 => {
                    prev.r = bytes[idx];
                    prev.g = bytes[idx + 1];
                    prev.b = bytes[idx + 2];
                    prev.a = bytes[idx + 3];
                    idx += 4;
                },
                else => switch ((tag_byte & 0xc0) >> 6) {
                    // QOI_OP_INDEX
                    0b00 => {
                        prev = index[tag_byte];
                    },
                    // QOI_OP_DIFF
                    0b01 => {
                        prev.r +%= ((tag_byte >> 4) & 0x03) -% 2;
                        prev.g +%= ((tag_byte >> 2) & 0x03) -% 2;
                        prev.b +%= (tag_byte & 0x03) -% 2;
                    },
                    // QOI_OP_LUMA
                    0b10 => {
                        const b = bytes[idx];
                        idx += 1;
                        const green_diff = (tag_byte & 0x3f) -% 32;
                        prev.r +%= green_diff -% 8 +% ((b >> 4) & 0x0f);
                        prev.g +%= green_diff;
                        prev.b +%= green_diff -% 8 +% (b & 0x0f);
                    },
                    // QOI_OP_RUN
                    0b11 => {
                        runs = tag_byte & 0x3f;
                    },
                    else => unreachable,
                },
            }

            index[prev.hash()] = prev;
        }

        pixels[px_idx] = prev.r;
        pixels[px_idx + 1] = prev.g;
        pixels[px_idx + 2] = prev.b;
        if (header.channels == @intFromEnum(Channel.rgba))
            pixels[px_idx + 3] = prev.a;
    }

    // std.debug.assert(std.mem.eql(u8, bytes[idx..], &byte_stream_suffix));

    return .{
        .pixels = pixels,
        .width = header.width,
        .height = header.height,
        .channels = @enumFromInt(header.channels),
        .colorspace = @enumFromInt(header.colorspace),
    };
}
