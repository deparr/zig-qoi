const std = @import("std");
const builtin = @import("builtin");

const qoi = @import("qoi");
const zimg = @import("zigimg");

const usage =
    \\Usage:
    \\  qoi [in_file] [out_file]
    \\
    \\  Converts [in_file] to [out_file].
    \\  Formats are assumed from file extensions.
    \\  Use '-' to refer to stdin / stdout.
    \\
    \\  If only [in_file] is given, reports if [in_file] contains a QOI image.
;

const Format = enum {
    qoi,
    png,
    bmp,

    fn fromPath(path: []const u8) ?Format {
        const ext = std.fs.path.extension(path);
        return std.meta.stringToEnum(Format, if (ext.len > 0) ext[1..] else ext);
    }
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2 or eql(args[1], "--help")) {
        var stderr = std.fs.File.stderr().writer(&.{});
        try stderr.interface.writeAll(usage);
        return;
    }

    var iobuf: [2048]u8 = undefined;

    if (args.len == 2) {
        const subject_bytes = try std.fs.cwd().readFile(args[1], &iobuf);
        var stdout = std.fs.File.stdout().writer(&iobuf);
        if (qoi.Desc.decode(subject_bytes)) |desc| {
            try stdout.interface.print("{any}\n", .{ desc });
        } else |err| {
            try stdout.interface.print("{t}\n", .{ err });
        }
        try stdout.interface.flush();
        return;
    }

    const in_path = args[1];
    const out_path = args[2];

    var input_format: ?Format = Format.fromPath(in_path);
    var output_format: ?Format = Format.fromPath(out_path);

    if (input_format == null and output_format == null) {
        std.log.info("neither infile or outfile have valid extensions. assuming qoi -> png", .{});
        input_format = .qoi;
        output_format = .png;
    } else if (input_format == null) {
        if (output_format.? == .qoi) {
            std.log.info("<null> -> qoi, assuming png -> qoi", .{});
            input_format = .png;
        } else {
            input_format = .qoi;
        }
    } else if (output_format == null) {
        if (input_format.? == .qoi) {
            std.log.info("qoi -> <null>, assuming qoi -> png", .{});
            output_format = .png;
        } else {
            output_format = .qoi;
        }
    } else if (output_format == input_format) {
        std.log.info("input and output formats match. exiting", .{});
        return;
    } else if (output_format != .qoi and input_format != .qoi) {
        return error.MissingQoiInput;
    }

    var infile_handle: ?std.fs.File = null;
    const infile_reader = blk: {
        if (eql(in_path, "-")) {
            var r = std.fs.File.stdin().reader(&iobuf);
            break :blk &r.interface;
        }
        infile_handle = try std.fs.cwd().openFile(in_path, .{ .mode = .read_only });
        var r = infile_handle.?.reader(&iobuf);
        break :blk &r.interface;
    };

    const input_bytes = try infile_reader.allocRemaining(gpa, .limited(1 << 20));
    if (infile_handle) |f| f.close();
    defer gpa.free(input_bytes);

    var out_file_was_stdout = false;
    const out_file = blk: {
        if (eql(out_path, "-")) {
            out_file_was_stdout = true;
            break :blk std.fs.File.stdout();
        }
        break :blk try std.fs.cwd().createFile(out_path, .{});
    };

    if (input_format == .qoi) {
        const image = try qoi.decode(gpa, input_bytes);
        defer image.deinit(gpa);

        switch (output_format.?) {
            .png => {
                var z_image = try zimg.Image.fromRawPixels(
                    gpa,
                    image.width,
                    image.height,
                    image.pixels,
                    if (image.channels == .rgb) .rgb24 else .rgba32,
                );
                defer z_image.deinit(gpa);

                try z_image.writeToFile(
                    gpa,
                    out_file,
                    &iobuf,
                    .{ .png = .{} },
                );
            },
            .bmp => {
                var writer = out_file.writer(&iobuf);
                try writeBitmap(&writer.interface, image);
                try writer.interface.flush();
            },
            else => unreachable,
        }
    } else {
        var image = try zimg.Image.fromMemory(gpa, input_bytes);
        defer image.deinit(gpa);
        const pixel_format = image.pixelFormat();
        const channels: qoi.Channel = switch (pixel_format) {
            .rgba32 => .rgba,
            else => .rgb,
        };
        const qoi_bytes = try qoi.encode(gpa, image.pixels.asConstBytes(), .{
            .width = @truncate(image.width),
            .height = @truncate(image.height),
            .channels = channels,
            .colorspace = .srgb,
        });
        defer gpa.free(qoi_bytes);

        var writer = out_file.writer(&iobuf);
        try writer.interface.writeAll(qoi_bytes);
        try writer.interface.flush();

        if (!out_file_was_stdout)
            out_file.close();
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn writeBitmap(w: *std.Io.Writer, img: qoi.Image) !void {
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

    const channels = @intFromEnum(img.channels);
    for (0..img.height) |row| {
        const flipped = img.height - row - 1;

        const row_start_pos = flipped * img.width * channels + flipped * padding;
        for (0..img.width) |col| {
            const px_pos = row_start_pos + col * channels;
            const r: u24 = img.pixels[px_pos];
            const g: u24 = img.pixels[px_pos + 1];
            const b: u24 = img.pixels[px_pos + 2];
            const pixel = r << 16 | g << 8 | b;
            try w.writeInt(u24, pixel, .little);
        }
        try w.splatByteAll(0, padding);
    }
}
