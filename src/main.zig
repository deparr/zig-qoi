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

    var namebuf: [128]u8 = undefined;

    for ([_][]const u8{
        "dice",
        "edgecase",
        "kodim10",
        "kodim23",
        "qoi_logo",
        "testcard",
        "testcard_rgba",
        "wikipedia_008",
    }) |impath| {
        const pathname = try std.fmt.bufPrint(&namebuf, "qoi_test_images/{s}.qoi", .{impath});
        const qoi_bytes = try std.fs.cwd().readFileAlloc(gpa, pathname, 2 * 1024 * 1024);
        defer gpa.free(qoi_bytes);
        const image = try qoi.decode(gpa, qoi_bytes);
        defer gpa.free(image.pixels);

        const outpathname = try std.fmt.bufPrintZ(&namebuf, "decoded_{s}.png", .{impath});
        if (stb.write_png(
            @ptrCast(outpathname.ptr),
            @intCast(image.width),
            @intCast(image.height),
            @intCast(@intFromEnum(image.channels)),
            @ptrCast(image.pixels.ptr),
            0,
        ) == 0) std.debug.print("{s}: failed to write decoded png", .{impath});
    }
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
