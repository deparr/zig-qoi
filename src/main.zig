const std = @import("std");
const qoi = @import("qoi.zig");
const stb = @import("stb.zig");

pub fn main() !void {
    var buf: [4096]u8 = undefined;

    const qoi_bytes = try std.fs.cwd().readFile("qoi_test_images/edgecase.qoi", &buf);
    const header = try qoi.Header.decode(qoi_bytes);
    std.debug.print("{d}x{d} ({d}) @ {d}\n", .{
        header.width,
        header.height,
        header.width * header.height,
        header.channels,
    });
    const image = try qoi.decode(std.heap.page_allocator, qoi_bytes);
    defer std.heap.page_allocator.free(image.pixels);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_f = std.fs.File.stdout();
    var stdout = stdout_f.writer(&stdout_buf);
    try stdout.interface.writeAll(image.pixels);

    // var x: c_int = 0;
    // var y: c_int = 0;
    // var n: c_int = 0;
    // const imf = stb.load("qoi_test_images/edgecase.png", &x, &y, &n, 0);
    // defer stb.image_free(imf);
    // const res = stb.write_png("png_to_png.png", x, y, n, imf, x * n);
    // if (res == 0) {
    //     std.debug.print("pngpng res was 0\n", .{});
    // }
    // try stdout.interface.writeAll(imf[0..@intCast(x * y * n)]);
    // const imm = stb.load_from_memory(@ptrCast(image.pixels.ptr), @intCast(image.pixels.len), &x, &y, &n, 0);
    // if (@intFromPtr(imm) == 0) {
    //     std.debug.print("imm was null\n", .{});
    // } else {
    //     res = stb.write_png("qoi_to_png.png", x, y, n, imm, x * n);
    //     if (res == 0) {
    //         std.debug.print("qoipng res was 0\n", .{});
    //     }
    // }
    // stb.image_free(imm);
}
