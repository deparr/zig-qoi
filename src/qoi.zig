const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_pixels = 400_000_000;
pub const encoding_epilogue = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };
pub const signature = [4]u8{ 'q', 'o', 'i', 'f' };
pub const magic_number = 0x716f6966;

pub const DecodeError = error{ TooSmall, MissingSignature, ZeroDimension, InvalidChannel, InvalidColorspace, ImageTooLarge, OutOfMemory, InvalidEncoding, WriteFailed };
pub const EncodeError = error{ EmptyPixelBuffer, ZeroPixelCount, ImageTooLarge, OutOfMemory, WriteFailed };

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
        if (data.len < size) return error.TooSmall;
        if (std.mem.readInt(u32, data[0..4], .big) != magic_number) return error.MissingSignature;

        const width = std.mem.readInt(u32, data[4..8], .big);
        const height = std.mem.readInt(u32, data[8..12], .big);
        const channels = data[12];
        const colorspace = data[13];

        if (width == 0 or height == 0) return error.ZeroDimension;

        return .{
            .width = width,
            .height = height,
            .channels = std.enums.fromInt(Channel, channels) orelse return error.InvalidChannel,
            .colorspace = std.enums.fromInt(Colorspace, colorspace) orelse return error.InvalidColorspace,
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

    pub fn rgb(self: Pixel) u24 {
        return @as(u24, self.r) << 16 | @as(u24, self.g) << 8 | @as(u24, self.b);
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
pub fn encodeAlloc(gpa: Allocator, pixels: []const u8, desc: Desc) EncodeError![]u8 {
    const estimated_size = @max(pixels.len * 32 / 100, 512);
    var allocating = try std.Io.Writer.Allocating.initCapacity(gpa, estimated_size);
    errdefer allocating.deinit();

    try encode(&allocating.writer, pixels, desc);

    return allocating.toOwnedSlice();
}

/// encodes `pixels` as QOI and writes the result into `stream`
///
/// Note: writes a qoi header before any pixel encodings.
/// Note: the qoi epilogue is written to `stream` after the pixel encodings
pub fn encode(stream: *std.Io.Writer, pixels: []const u8, desc: Desc) EncodeError!void {
    const pixel_count = desc.height * desc.width;

    if (pixels.len == 0) return error.EmptyPixelBuffer;
    if (pixel_count == 0) return error.ZeroPixelCount;
    if (pixel_count >= max_pixels) return error.ImageTooLarge;

    const channels = @intFromEnum(desc.channels);

    // better errors?
    // write header
    try stream.writeAll(&signature);
    try stream.writeInt(u32, desc.width, .big);
    try stream.writeInt(u32, desc.height, .big);
    try stream.writeByte(channels);
    try stream.writeByte(@intFromEnum(desc.colorspace));

    var index: [64]Pixel = .{Pixel{ .a = 0 }} ** 64;
    var prev_pixel = Pixel{};
    var curr_pixel = Pixel{};
    var run_len: u8 = 0;

    const pixel_len = pixel_count * channels;
    const last_pixel = pixel_len - channels;
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
            if (run_len == 62 or pixel_offset == last_pixel) {
                try stream.writeByte(Encoding.run | (run_len - 1));
                run_len = 0;
            }
        } else {
            var index_pos: u8 = 0;

            // finish an active run
            if (run_len > 0) {
                try stream.writeByte(Encoding.run | (run_len - 1));
                run_len = 0;
            }

            index_pos = curr_pixel.hash();

            // save an index
            if (index[index_pos] == curr_pixel) {
                try stream.writeByte(Encoding.index | index_pos);
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
                        try stream.writeByte(Encoding.diff | r_diff2 | g_diff2 | b_diff2);

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
                        try stream.writeByte(Encoding.luma | g_diff2);
                        try stream.writeByte(rg_diff2 | bg_diff2);

                        // store single rgb pixel
                    } else {
                        try stream.writeByte(Encoding.rgb);
                        try stream.writeInt(u24, curr_pixel.rgb(), .big);
                    }

                    // store single rgba pixel
                } else {
                    try stream.writeByte(Encoding.rgba);
                    try stream.writeStruct(curr_pixel, .big);
                }
            }
        }

        prev_pixel = curr_pixel;
    }

    try stream.writeAll(&encoding_epilogue);
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
pub fn decodeAlloc(gpa: Allocator, data: []const u8) DecodeError!Image {
    var allocating = try std.Io.Writer.Allocating.initCapacity(gpa, data.len * 32);
    errdefer allocating.deinit();
    const desc = try decode(&allocating.writer, data);
    return .{
        .pixels = try allocating.toOwnedSlice(),
        .width = desc.width,
        .height = desc.height,
        .channels = desc.channels,
        .colorspace = desc.colorspace,
    };
}

/// decodes a `qoi` image from `data` into `stream`
///
/// on error.InvalidEncoding the stream may have received a partially decoded
/// image
pub fn decode(stream: *std.Io.Writer, data: []const u8) DecodeError!Desc {
    const desc = try Desc.decode(data);

    const pixel_count = desc.width * desc.height;
    if (pixel_count > max_pixels) return error.ImageTooLarge;

    var index: [64]Pixel = .{Pixel{ .a = 0 }} ** 64;
    var prev_pixel = Pixel{};
    var run_len: u8 = 0;

    var read_offset: u32 = Desc.size;
    // todo this is kinda sus
    const last_encoding = data.len - encoding_epilogue.len;
    for (0..pixel_count) |_| {
        if (run_len > 0) {
            run_len -= 1;
        } else if (read_offset < last_encoding) {
            const tag = data[read_offset];
            read_offset += 1;
            switch (tag) {
                Encoding.rgb => {
                    prev_pixel.r = data[read_offset];
                    prev_pixel.g = data[read_offset + 2];
                    prev_pixel.b = data[read_offset + 1];
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

        if (desc.channels == .rgba) {
            try stream.writeStruct(prev_pixel, .big);
        } else {
            try stream.writeInt(u24, prev_pixel.rgb(), .big);
        }
    }

    return desc;
}

test "Pixel hashing" {
    var black = Pixel{};
    var magenta = Pixel{ .r = 255, .b = 255 };
    try std.testing.expectEqual(53, black.hash());
    try std.testing.expectEqual(43, magenta.hash());
}
