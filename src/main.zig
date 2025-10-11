const std = @import("std");
const qoi = @import("qoi.zig");
const stb = @import("stb.zig");
const builtin = @import("builtin");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var x: c_int = 0;
    var y: c_int = 0;
    var n: c_int = 0;
    const image = @as([*]u8, stb.load("qoi_test_images/edgecase.png", &x, &y, &n, 4));
    std.debug.print("{d}x{d}@{d}\n", .{x, y, n });

    const encoded_qoi_bytes = try qoi.encode(gpa, image[0..@intCast(x * y * 4)], .{
        .width = @intCast(x),
        .height = @intCast(y),
        .channels = .rgba,
        .colorspace = .srgb,
    });
    defer gpa.free(encoded_qoi_bytes);

    var iobuf: [2048]u8 = undefined;

    var stdout_f = std.fs.File.stdout();
    var stdout_w = stdout_f.writer(&iobuf);
    var stdout = &stdout_w.interface;
    try stdout.writeAll(encoded_qoi_bytes);
    try stdout.flush();
}

fn writeBitmap(w: *std.Io.Writer, img: qoi.Qoi) !void {
    const padding = img.width % 4;
    const file_size = 54 + img.width * img.height * 3 + padding * (img.height - 1);
    try w.writeAll("BM");
    try w.writeInt(u32, file_size, .little);
    try w.writeInt(u32, 0, .little); // reserved
    try w.writeInt(u32, 54, .little); // offset to pixels
    try w.writeInt(u32, 40, .little); // dib header size
    try w.writeInt(u32, img.width, .little);
    try w.writeInt(u32, img.height, .little);
    try w.writeInt(u16, 1, .little); // color planes
    try w.writeInt(u16, 24, .little); // bits per pixel
    try w.writeInt(u32, 0, .little); // compression
    try w.writeInt(u32, file_size - 54, .little); // raw bitmap size
    try w.writeInt(u32, 2835, .little); // print resolution
    try w.writeInt(u32, 2835, .little); // print resolution
    try w.writeInt(u32, 0, .little); // palette colors
    try w.writeInt(u32, 0, .little); // important colors

    for (0..img.height) |row| {
        const flipped = img.height - row - 1;

        const row_start_pos = flipped * img.width * 4 + flipped * padding;
        for (0..img.width) |col| {
            const px_pos = row_start_pos + col * 4;
            const r: u24 = img.pixels[px_pos];
            const g: u24 = img.pixels[px_pos + 1];
            const b: u24 = img.pixels[px_pos + 2];
            const pixel: u24 = r << 16 | g << 8 | b;
            try w.writeInt(u24, pixel, .little);
        }

        _ = try w.splatByte(0, padding);
    }

    try w.flush();
}
