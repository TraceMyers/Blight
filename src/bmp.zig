const std = @import("std");
const string = @import("string.zig");
const imagef = @import("image.zig");
const time = @import("time.zig");
const readerf = @import("reader.zig");
const types = @import("types.zig");
const config = @import("config.zig");
const filef = @import("file.zig");

const LocalStringBuffer = string.LocalStringBuffer;
const print = std.debug.print;
const Image = imagef.Image;
const ImageError = imagef.ImageError;
const InlinePixelReader = readerf.InlinePixelReader;
const BmpRLEReader = readerf.BmpRLEReader;
const RLEAction = readerf.RLEAction;
const ColorLayout = readerf.ColorLayout;

// calibration notes for when it becomes useful:

// X = Sum_lambda=(380)^780 [S(lambda) xbar(lambda)]
// Y = Sum_lambda=(380)^780 [S(lambda) ybar(lambda)]
// Z = Sum_lambda=(380)^780 [S(lambda) zbar(lambda)]
// the continuous version is the same, but integrated over lambda, 0 to inf. S(lambda) also called I(lambda)

// ybar color-matching function == equivalent response of the human eye to range of of light on visible spectrum
// Y is CIE Luminance, indicating overall intensity of light

// Color Intensity = (Voltage + MonitorBlackLevel)^(Gamma)
// where MonitorBlackLevel is ideally 0
// for most monitors, g ~ 2.5
// 0 to 255 ~ corresponds to voltage range of a pixel p

// "Lightness" value, approximate to human perception...
// L* = if (Y/Yn <= 0.008856) 903.3 * (Y/Yn);
//      else 116 * (Y/Yn)^(1/3) - 16
//      in (0, 100)
// ... where each integral increment of L* corresponds to a perceivably change in lightness
// ... and where Yn is a white level.

// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// -------------------------------------------------------------------------------------------------------- entry points
// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

pub fn load(
    file: *std.fs.File, image: *Image, allocator: std.mem.Allocator, options: *const types.ImageLoadOptions
) !void {
    const buffer: []align(4) u8 = try loadFileAndCoreHeaders(file, allocator, bmp_min_sz);
    defer allocator.free(buffer);

    if (!validateIdentity(buffer)) {
        try imagef.redirectLoad(file, image, allocator, options, imagef.ImageFormat.Bmp);
        return;
    }

    var info = BitmapInfo{};
    if (!readInitial(buffer, &info)) {
        return ImageError.BmpInvalidBytesInFileHeader;
    }
    if (buffer.len <= info.header_sz + bmp_file_header_sz or buffer.len <= info.data_offset) {
        return ImageError.UnexpectedEOF;
    }

    try loadRemainder(file, buffer, &info);

    var color_table = BitmapColorTable{};
    var buffer_pos: usize = undefined;
    switch (info.header_sz) {
        bmp_info_header_sz_core => buffer_pos = try readCoreInfo(buffer, &info, &color_table),
        bmp_info_header_sz_v1 => buffer_pos = try readV1Info(buffer, &info, &color_table),
        bmp_info_header_sz_v4 => buffer_pos = try readV4Info(buffer, &info, &color_table),
        bmp_info_header_sz_v5 => buffer_pos = try readV5Info(buffer, &info, &color_table),
        else => return ImageError.BmpInvalidHeaderSizeOrVersionUnsupported,
    }

    if (!colorSpaceSupported(&info)) {
        return ImageError.BmpColorSpaceUnsupported;
    }
    if (!compressionSupported(&info)) {
        return ImageError.BmpCompressionUnsupported;
    }

    try createImage(buffer, image, &info, &color_table, allocator, options);
}

pub fn save(
    file: *std.fs.File, image: *const Image, allocator: std.mem.Allocator, options: *const types.ImageSaveOptions
) !void {
    var info: BitmapInfo = BitmapInfo{};
    var temp_table = BitmapColorTable{};
    var color_table = BitmapColorTable{};

    try determineOutputFormat(image, &info, options, &temp_table);
    writePreliminaryInfo(image, &info);

    // for non-rle images, row size == max_row_sz. bmp rows are aligned to 4 bytes
    const unaligned_max_row_bits = image.width * info.color_depth;
    const max_row_sz = bmpRowSz(unaligned_max_row_bits);
    const max_image_sz = max_row_sz * image.height;
    const alloc_sz: u32 = info.data_offset + max_image_sz;
    var buffer: []u8 = try allocator.alloc(u8, alloc_sz);
    defer allocator.free(buffer);
    @memset(buffer, 0);

    try writePixelDataToBuffer(buffer, image, &info, &temp_table);

    try writeV4InfoToBuffer(buffer, &info, &temp_table, &color_table);

    print("saving file with compression {any}, color depth {}\n", .{info.compression, info.color_depth});

    const write_buffer = buffer[0..info.file_sz];
    try file.writeAll(write_buffer);
}

// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// ----------------------------------------------------------------------------------------------- gathering information
// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

fn writePixelDataToBuffer(buffer: []u8, image: *const Image, info: *BitmapInfo, temp_table: *BitmapColorTable) !void {
    switch (info.compression) {
        .RGB => {
            switch (info.color_depth) {
                inline 1, 4, 8 => |depth| try writeColorTablePixelDataToBuffer(depth, buffer, image, info, temp_table), 
                inline 16, 24, 32 => |depth| writeInlinePixelDataToBuffer(depth, false, buffer, image, info), 
                else => unreachable,
            }
        }, 
        .BITFIELDS => writeInlinePixelDataToBuffer(16, false, buffer, image, info), 
        .RLE8 => writeRlePixelDataToBuffer(8, buffer, image, info, temp_table),
        else => unreachable,
    }
}

fn writeColorTablePixelDataToBuffer(
    comptime color_depth: comptime_int, buffer: []u8, image: *const Image, info: *BitmapInfo, temp_table: *BitmapColorTable
) !void {
    const row_sz: u32 = bmpRowSz(@as(u32, @intCast(info.width)) * info.color_depth);
    var buf_row_begin: usize = info.data_offset + row_sz * (@as(u32, @intCast(info.height)) - 1);
    var img_row_begin: usize = 0;

    const colors_per_byte: comptime_int = 8 / color_depth;

    // the palette should only be empty here if the output type was determined with determineOutputFormatFast(),
    // which only selects color table image output when the input image is 8bit grey.
    const direct_greyscale: bool = temp_table.palette.isEmpty();
    if (direct_greyscale and (color_depth != 8 or image.activePixelTag() != .R8)) {
        return ImageError.BmpWriteColorTableFailure;
    }

    switch (image.activePixelTag()) {
        inline .RGBA32, .RGB16, .R8, .R16 => |tag| {
            const image_pixels = try image.getPixels(tag);
            const palette_pixels = try temp_table.palette.getPixels(tag);
            for (0..image.height) |row| {
                _ = row;
                const img_row_end = img_row_begin + image.width;

                var buffer_row: [*]u8 = @ptrCast(&buffer[buf_row_begin]);
                const image_row: []tag.toType() = image_pixels[img_row_begin..img_row_end];

                var row_idx: usize = 0;
                write_row: for (0..row_sz) |byte| {
                    const buffer_byte: *u8 = &buffer_row[byte];
                    inline for (0..colors_per_byte) |byte_idx| {
                        if (row_idx + byte_idx >= image_row.len) {
                            break :write_row;
                        }
                        const image_row_idx = row_idx + byte_idx;
                        const color: tag.toType() = image_row[image_row_idx];

                        if (direct_greyscale) {
                            switch (@TypeOf(color)) {
                                inline types.R8 => buffer_byte.* = @as(u8, @bitCast(color)),
                                else => unreachable,
                            }
                        } else {
                            var index: usize = std.math.maxInt(usize);
                            for (0..palette_pixels.len) |i| {
                                if (std.meta.eql(palette_pixels[i], color)) {
                                    index = i;
                                    break;
                                }
                            }
                            if (index > std.math.maxInt(u8)) {
                                return ImageError.BmpWriteColorTableFailure;
                            }
                            const index_write_shift: comptime_int = (colors_per_byte - byte_idx - 1) * color_depth;
                            buffer_byte.* |= @as(u8, @intCast(index)) << index_write_shift;
                        }
                    }
                    row_idx += colors_per_byte;
                }

                buf_row_begin -= row_sz;
                img_row_begin += image.width;
            }
        }, else => unreachable,
    }

    info.data_size = row_sz * @as(u32, @intCast(info.height));
    info.file_sz = @as(u32, @intCast(buffer.len));
}

fn writeInlinePixelDataToBuffer(
    comptime color_depth: comptime_int, comptime is_grey: bool, buffer: []u8, image: *const Image, info: *BitmapInfo, 
) void {
    _ = color_depth;
    _ = image;
    _ = is_grey;


    // TODO:
    // info.data_sz =
    info.file_sz = @as(u32, @intCast(buffer.len));
}

fn writeRlePixelDataToBuffer(
    comptime color_depth: comptime_int, buffer: []u8, image: *const Image, info: *BitmapInfo, temp_table: *BitmapColorTable
) void {
    _ = color_depth;
    _ = buffer;
    _ = image;
    _ = info;
    _ = temp_table;

   //  var buf_row_begin: usize = info.data_offset;
   //  var img_row_begin: usize = 0;
   //  

   //  const img_row_end = img_row_begin + image.width;

   //  var buffer_row: [*]u8 = @ptrCast(&buffer[buf_row_begin]);
   //  const image_row: []tag.toType() = image_pixels[img_row_begin..img_row_end];

    // TODO:
    // info.data_sz =
    // info.file_sz = 
}

inline fn determineOutputFormat(
    image: *const Image, info: *BitmapInfo, options: *const types.ImageSaveOptions, table: *BitmapColorTable
) !void {
    if (options.strategy == .Fast) {
        try determineOutputFormatFast(image, info, table);
    } else { // Small
        try determineOutputFormatSmall(image, info, table);
    }
}

inline fn writePreliminaryInfo(image: *const Image, info: *BitmapInfo) void {
    info.data_offset = alignTo(4, bmp_file_header_sz + bmp_info_header_sz_v4 + info.color_ct * @sizeOf(types.BGR32));
    info.header_sz = bmp_info_header_sz_v4;
    info.header_type = BitmapHeaderType.V4;
    info.width = @as(i32, @intCast(image.width));
    info.height = @as(i32, @intCast(image.height));
    info.color_space = BitmapColorSpace.WindowsCS;
}

fn determineOutputFormatFast(image: *const Image, info: *BitmapInfo, table: *BitmapColorTable) !void {
    switch (image.activePixelTag()) {
        .R8 => {
            info.compression = BitmapCompression.RGB;
            info.color_depth = 8;
            info.color_ct = 256;
            try table.palette.attachToBuffer(table.buffer[0..256], types.PixelTag.R8, 256, 1);
            const table_pixels = try table.palette.getPixels(.R8);
            for (0..256) |i| {
                table_pixels[i].r = @as(u8, @intCast(i));
            }
        }, .R16 => {
            info.compression = BitmapCompression.BITFIELDS;
            info.color_depth = 16;
            info.color_ct = 0;
            info.red_mask = 0xffff;
        }, .RGB16 => {
            info.compression = BitmapCompression.RGB;
            info.color_depth = 16;
            info.color_ct = 0;
        }, .RGBA32 => {
            info.compression = BitmapCompression.RGB;
            if (image.alpha == .None) {
                info.color_depth = 24;
                info.color_ct = 0;
            } else {
                info.color_depth = 32;
                info.color_ct = 0;
                info.alpha_mask = 0xff000000;
            }
        }, else => unreachable,
    }
}

fn determineOutputFormatSmall(image: *const Image, info: *BitmapInfo, table: *BitmapColorTable) !void {
    var color_ct: usize = undefined;
    var rle_byte_difference: i64 = undefined;
    var can_color_map: bool = undefined;
    try table.palette.attachToBuffer(
        table.buffer[0..table.buffer.len], 
        image.activePixelTag(), 
        @as(u32, @intCast(table.buffer.len / image.activePixelTag().size())), 
        1
    );

    try imagef.determineColorMapAndRleSizeCosts(
        imagef.RleType.Bmp, image, &table.palette, &color_ct, &rle_byte_difference, &can_color_map
    );

    print("color ct: {}, can color map: {}\n", .{color_ct, can_color_map});

    if (can_color_map) {
        const color_map_pixel_sz: usize = switch(color_ct) {
            2 => 1,
            3...16 => 4,
            else => 8,
        };
        // for greater compatibility, force color map images to have table sizes fixed by their color depth
        color_ct = switch(color_map_pixel_sz) {
            1 => 2,
            4 => 16,
            8 => 256,
            else => unreachable,
        };
        table.palette.setBytesLen(color_ct);

        const color_map_img_sz: i64 = @intCast(color_map_pixel_sz * image.len() + @sizeOf(types.RGB32) * color_ct);
        const rle_img_sz: i64 = @as(i64, @intCast(@sizeOf(u8) * image.len() + @sizeOf(types.RGB32) * 256)) 
            + rle_byte_difference;
        const default_pixel_sz: i64 = if (image.activePixelTag() == .RGBA32 and image.alpha == .None) 
            3
            else @as(i64, @intCast(image.activePixelTag().size()));
        const default_img_sz: i64 = default_pixel_sz * @as(i64, @intCast(image.len()));

        if (default_img_sz <= color_map_img_sz and default_img_sz <= rle_img_sz) {
            // probably inline color image
            table.palette.unattachFromBuffer();
            try determineOutputFormatFast(image, info, table);
        } else if (color_map_img_sz < rle_img_sz) {
            // color table image
            info.compression = BitmapCompression.RGB;
            info.color_depth = @intCast(color_map_pixel_sz);
            info.color_ct = @intCast(color_ct);
        } else {
            // rle compression
            info.compression = BitmapCompression.RLE8;
            info.color_depth = 8;
            info.color_ct = 256;
        }
    } else {
        table.palette.unattachFromBuffer();
        try determineOutputFormatFast(image, info, table);
    }
}

fn loadFileAndCoreHeaders(file: *std.fs.File, allocator: std.mem.Allocator, min_sz: usize) ![]align(4) u8 {
    const stat = try file.stat();
    if (stat.size + 4 > config.max_alloc_sz) {
        return ImageError.AllocTooLarge;
    }
    if (stat.size < min_sz) {
        return ImageError.InvalidSizeForFormat;
    }

    var buffer: []align(4) u8 = try allocator.alignedAlloc(u8, 4, stat.size + 4);

    for (0..bmp_file_header_sz + bmp_info_header_sz_core) |i| {
        buffer[i] = try file.reader().readByte();
    }

    return buffer;
}

fn loadRemainder(file: *std.fs.File, buffer: []u8, info: *BitmapInfo) !void {
    const cur_offset = bmp_file_header_sz + bmp_info_header_sz_core;
    if (info.data_offset > bmp_file_header_sz + bmp_info_header_sz_v5 + @sizeOf(types.RGBA32) * 256 + 4 
        or info.data_offset <= cur_offset
    ) {
        return ImageError.BmpInvalidBytesInInfoHeader;
    }

    for (cur_offset..info.data_offset) |i| {
        buffer[i] = try file.reader().readByte();
    }

    // aligning pixel data to a 4 byte boundary (requirement)
    const offset_mod_4 = info.data_offset % 4;
    const offset_mod_4_neq_0: u32 = @intFromBool(offset_mod_4 != 0);
    info.data_offset = info.data_offset + offset_mod_4_neq_0 * (4 - offset_mod_4);

    const data_buf: []u8 = buffer[info.data_offset..];
    _ = try file.reader().read(data_buf);
}

inline fn readInitial(buffer: []const u8, info: *BitmapInfo) bool {
    info.file_sz = std.mem.readInt(u32, buffer[2..6], .little);
    const reserved_verify_zero = std.mem.readInt(u32, buffer[6..10], .little);
    if (reserved_verify_zero != 0) {
        return false;
    }
    info.data_offset = std.mem.readInt(u32, buffer[10..14], .little);
    info.header_sz = std.mem.readInt(u32, buffer[14..18], .little);
    return true;
}

fn validateIdentity(buffer: []const u8) bool {
    const identity = buffer[0..2];
    if (string.same(identity, filef.bmp_identifier)) {
        return true;
    }
    return false;
}

fn readCoreInfo(buffer: []u8, info: *BitmapInfo, color_table: *BitmapColorTable) !usize {
    info.header_type = BitmapHeaderType.Core;
    info.width = @intCast(std.mem.readInt(i16, buffer[18..20], .little));
    info.height = @intCast(std.mem.readInt(i16, buffer[20..22], .little));
    info.color_depth = @intCast(std.mem.readInt(u16, buffer[24..26], .little));
    const data_size_signed = @as(i32, @intCast(info.file_sz)) - @as(i32, @intCast(info.data_offset));
    if (data_size_signed < 4) {
        return ImageError.BmpInvalidBytesInInfoHeader;
    }
    info.data_size = @intCast(data_size_signed);
    info.compression = BitmapCompression.RGB;
    const table_offset = bmp_file_header_sz + bmp_info_header_sz_core;
    try readColorTable(buffer[table_offset..], info, color_table, types.BGR24);
    return table_offset + color_table.palette.len() * @sizeOf(types.BGR24);
}

fn readV1Info(buffer: []u8, info: *BitmapInfo, color_table: *BitmapColorTable) !usize {
    info.header_type = BitmapHeaderType.V1;
    try readV1HeaderPart(buffer, info);
    var mask_offset: usize = 0;
    if (info.compression == BitmapCompression.BITFIELDS) {
        readColorMasks(buffer, info, false);
        mask_offset = 12;
    } else if (info.compression == BitmapCompression.ALPHABITFIELDS) {
        readColorMasks(buffer, info, true);
        mask_offset = 16;
    }
    const table_offset = bmp_file_header_sz + bmp_info_header_sz_v1 + mask_offset;
    try readColorTable(buffer[table_offset..], info, color_table, types.BGR32);
    return table_offset + color_table.palette.len() * @sizeOf(types.BGR32);
}

fn readV4Info(buffer: []u8, info: *BitmapInfo, color_table: *BitmapColorTable) !usize {
    info.header_type = BitmapHeaderType.V4;
    try readV1HeaderPart(buffer, info);
    try readV4HeaderPart(buffer, info);
    const table_offset = bmp_file_header_sz + bmp_info_header_sz_v4;
    try readColorTable(buffer[table_offset..], info, color_table, types.BGR32);
    return table_offset + color_table.palette.len() * @sizeOf(types.BGR32);
}

fn readV5Info(buffer: []u8, info: *BitmapInfo, color_table: *BitmapColorTable) !usize {
    info.header_type = BitmapHeaderType.V5;
    try readV1HeaderPart(buffer, info);
    try readV4HeaderPart(buffer, info);
    readV5HeaderPart(buffer, info);
    const table_offset = bmp_file_header_sz + bmp_info_header_sz_v5;
    try readColorTable(buffer[table_offset..], info, color_table, types.BGR32);
    return table_offset + color_table.palette.len() * @sizeOf(types.BGR32);
}

fn readV1HeaderPart(buffer: []u8, info: *BitmapInfo) !void {
    info.width = std.mem.readInt(i32, buffer[18..22], .little);
    info.height = std.mem.readInt(i32, buffer[22..26], .little);
    info.color_depth = @intCast(std.mem.readInt(u16, buffer[28..30], .little));
    const compression_int = std.mem.readInt(u32, buffer[30..34], .little);
    if (compression_int > 9) {
        return ImageError.BmpInvalidBytesInInfoHeader;
    }
    info.compression = @enumFromInt(compression_int);
    info.data_size = std.mem.readInt(u32, buffer[34..38], .little);
    info.color_ct = std.mem.readInt(u32, buffer[46..50], .little);
}

fn readV4HeaderPart(buffer: []u8, info: *BitmapInfo) !void {
    readColorMasks(buffer, info, true);
    const color_space_int = std.mem.readInt(u32, buffer[70..74], .little);
    if (color_space_int != 0 
        and color_space_int != 0x4c494e4b 
        and color_space_int != 0x4d424544 
        and color_space_int != 0x57696e20 
        and color_space_int != 0x73524742
    ) {
        return ImageError.BmpInvalidBytesInInfoHeader;
    }
    info.color_space = @enumFromInt(color_space_int);
    if (info.color_space != BitmapColorSpace.CalibratedRGB) {
        return;
    }
    var buffer_casted: [*]align(1) FxPt2Dot30 = @ptrCast(@alignCast(&buffer[74]));
    @memcpy(info.cs_points.red[0..3], buffer_casted[0..3]);
    @memcpy(info.cs_points.green[0..3], buffer_casted[3..6]);
    @memcpy(info.cs_points.blue[0..3], buffer_casted[6..9]);
    info.red_gamma = std.mem.readInt(u32, buffer[110..114], .little);
    info.green_gamma = std.mem.readInt(u32, buffer[114..118], .little);
    info.blue_gamma = std.mem.readInt(u32, buffer[118..122], .little);
}

inline fn readV5HeaderPart(buffer: []u8, info: *BitmapInfo) void {
    info.profile_data = std.mem.readInt(u32, buffer[126..130], .little);
    info.profile_size = std.mem.readInt(u32, buffer[130..134], .little);
}

inline fn readColorMasks(buffer: []u8, info: *BitmapInfo, alpha: bool) void {
    info.red_mask = std.mem.readInt(u32, buffer[54..58], .little);
    info.green_mask = std.mem.readInt(u32, buffer[58..62], .little);
    info.blue_mask = std.mem.readInt(u32, buffer[62..66], .little);
    if (alpha) {
        info.alpha_mask = std.mem.readInt(u32, buffer[66..70], .little);
    }
}

noinline fn writeV4InfoToBuffer(
    buffer: []u8, info: *const BitmapInfo, temp_table: *const BitmapColorTable, color_table: *BitmapColorTable
) !void {
    writeCorePartToBuffer(buffer, info);
    writeV1HeaderPartToBuffer(buffer, info);
    writeV4HeaderPartToBuffer(buffer, info);
    if (!temp_table.palette.isEmpty()) {
        try writeColorTableToBuffer(buffer, info, temp_table, color_table);
    }
}

fn writeCorePartToBuffer(buffer: []u8, info: *const BitmapInfo) void {
    @memcpy(buffer[0..2], filef.bmp_identifier[0..2]);
    std.mem.writeInt(u32, buffer[2..6], info.file_sz, .little);
    @memset(buffer[6..10], @as(u8, 0));
    std.mem.writeInt(u32, buffer[10..14], info.data_offset, .little);
    std.mem.writeInt(u32, buffer[14..18], info.header_sz, .little);
}

fn writeV1HeaderPartToBuffer(buffer: []u8, info: *const BitmapInfo) void {
    std.mem.writeInt(i32, buffer[18..22], @as(i32, @intCast(info.width)), .little);
    std.mem.writeInt(i32, buffer[22..26], @as(i32, @intCast(info.height)), .little);
    std.mem.writeInt(u16, buffer[28..30], @as(u16, @intCast(info.color_depth)), .little);
    std.mem.writeInt(u32, buffer[30..34], @intFromEnum(info.compression), .little);
    std.mem.writeInt(u32, buffer[34..38], info.data_size, .little);
    std.mem.writeInt(u32, buffer[46..50], info.color_ct, .little);
}

fn writeV4HeaderPartToBuffer(buffer: []u8, info: *const BitmapInfo) void {
    writeColorMasksToBuffer(buffer, info);
    std.mem.writeInt(u32, buffer[70..74], @intFromEnum(info.color_space), .little);
    var buffer_casted: [*]align(1) FxPt2Dot30 = @ptrCast(@alignCast(&buffer[74]));
    @memcpy(buffer_casted[0..3], info.cs_points.red[0..3]);
    @memcpy(buffer_casted[3..6], info.cs_points.green[0..3]);
    @memcpy(buffer_casted[6..9], info.cs_points.blue[0..3]);
    std.mem.writeInt(u32, buffer[110..114], info.red_gamma, .little);
    std.mem.writeInt(u32, buffer[114..118], info.green_gamma, .little);
    std.mem.writeInt(u32, buffer[118..122], info.blue_gamma, .little);
}

fn writeColorMasksToBuffer(buffer: []u8, info: *const BitmapInfo) void {
    std.mem.writeInt(u32, buffer[54..58], info.red_mask, .little);
    std.mem.writeInt(u32, buffer[58..62], info.green_mask, .little);
    std.mem.writeInt(u32, buffer[62..66], info.blue_mask, .little);
    std.mem.writeInt(u32, buffer[66..70], info.alpha_mask, .little);
}

noinline fn writeColorTableToBuffer(
    buffer: []u8, info: *const BitmapInfo, temp_table: *const BitmapColorTable, color_table: *BitmapColorTable
) !void {
    if ((info.compression != .RGB and info.compression != .RLE8) or info.color_depth > 8) {
        return;
    }
    try color_table.palette.attachToBuffer(&color_table.buffer, .BGR32, info.color_ct, 1);
    var table_pixels: []types.BGR32 = try color_table.palette.getPixels(.BGR32);
    
    switch (temp_table.palette.activePixelTag()) {
        inline else => |tag| {
            const temp_pixels: []const tag.toType() = try temp_table.palette.getPixels(tag);
            for (0..info.color_ct) |i| {
                switch (comptime tag.toType()) {
                    types.R8, types.R16 => table_pixels[i].setFromGrey(temp_pixels[i]),
                    else => table_pixels[i].setFromColor(temp_pixels[i]),
                }
            }
        }
    }
    var buffer_casted_ptr: [*]align(2) types.BGR32 = 
        @as([*]align(2) types.BGR32, @ptrCast(@alignCast(&buffer[bmp_file_header_sz + bmp_info_header_sz_v4])));
    var buffer_casted = buffer_casted_ptr[0..info.color_ct];
    @memcpy(buffer_casted[0..info.color_ct], table_pixels[0..info.color_ct]);
}

fn readColorTable(
    buffer: []const u8, 
    info: *const BitmapInfo, 
    color_table: *BitmapColorTable, 
    comptime ColorType: type
) !void {
    // TODO: align of RGB24 must be 4, so.. how does this work with cores?
    var data_casted: [*]const ColorType = @ptrCast(@alignCast(&buffer[0]));
    var ct_len: u32 = 0;

    switch (info.color_depth) {
        32, 24, 16 => {
            ct_len = 0;
            return;
        },
        8, 4, 1 => {
            const max_color_ct = @as(u32, 1) << @intCast(info.color_depth);
            if (info.color_ct == 0) {
                ct_len = max_color_ct;
            } else if (info.color_ct >= 2 and info.color_ct <= max_color_ct) {
                ct_len = info.color_ct;
            } else {
                return ImageError.BmpInvalidColorCount;
            }
        },
        else => return ImageError.BmpInvalidColorDepth,
    }

    if (buffer.len <= ct_len * @sizeOf(ColorType)) {
        return ImageError.UnexpectedEOF;
    } else {
        var is_greyscale: bool = true;
        for (0..ct_len) |i| {
            const buffer_color: *const ColorType = &data_casted[i];
            if (buffer_color.r == buffer_color.g and buffer_color.g == buffer_color.b) {
                continue;
            }
            is_greyscale = false;
            break;
        }
        if (is_greyscale) {
            try color_table.palette.attachToBuffer(color_table.buffer[0..1024], types.PixelTag.R8, ct_len, 1);
            var ct_buffer = try color_table.palette.getPixels(types.PixelTag.R8);
            for (0..ct_len) |i| {
                const buffer_color: *const ColorType = &data_casted[i];
                const table_color: *types.R8 = &ct_buffer[i];
                table_color.r = buffer_color.r;
            }
        } else {
            try color_table.palette.attachToBuffer(color_table.buffer[0..1024], types.PixelTag.RGBA32, ct_len, 1);
            var ct_buffer = try color_table.palette.getPixels(types.PixelTag.RGBA32);
            for (0..ct_len) |i| {
                ct_buffer[i].setFromColor(data_casted[i]);
            }
        }
    }
}

pub fn colorSpaceSupported(info: *const BitmapInfo) bool {
    return switch (info.color_space) {
        // calibration information is unused because it doesn't make sense to calibrate individual textures in a game engine
        .CalibratedRGB => true,
        // I see no reason to support profiles. Seems like a local machine and/or printing thing
        .ProfileLinked => false,
        .ProfileEmbedded => false,
        .WindowsCS => true,
        .sRGB => true,
        .None => true,
    };
}

pub fn compressionSupported(info: *const BitmapInfo) bool {
    return switch (info.compression) {
        .RGB => true,
        .RLE8 => true,
        .RLE4 => true,
        .BITFIELDS => true,
        .JPEG => false,
        .PNG => false,
        .ALPHABITFIELDS => true,
        .CMYK => false,
        .CMYKRLE8 => false,
        .CMYKRLE4 => false,
        .None => false,
    };
}

inline fn bufferLongEnough(pixel_buf: []const u8, image: *const Image, row_length: usize) bool {
    return pixel_buf.len >= row_length * image.height;
}

// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// ---------------------------------------------------------------------------------------------------- creation helpers
// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

inline fn bytesPerRow(comptime PixelIntType: type, image_width: u32) u32 {
    var byte_ct_floor: u32 = undefined;
    var colors_per_byte: u32 = undefined;
    switch (PixelIntType) {
        u1 => {
            byte_ct_floor = image_width >> 3;
            colors_per_byte = 8;
        },
        u4 => {
            byte_ct_floor = image_width >> 1;
            colors_per_byte = 2;
        },
        u8 => {
            byte_ct_floor = image_width;
            colors_per_byte = 1;
        },
        else => unreachable,
    }
    const row_remainder_exists: u32 = @intFromBool((image_width - byte_ct_floor * colors_per_byte) > 0);
    return byte_ct_floor + row_remainder_exists;
}

// valid masks don't intersect, can't overflow their type (ie 17 bits used w/ 16 bit color), and according to the
// standard, they should also be contiguous, but I don't see why that matters.
fn validColorMasks(comptime PixelIntType: type, info: *const BitmapInfo) bool {
    const mask_intersection = info.red_mask & info.green_mask & info.blue_mask & info.alpha_mask;
    if (mask_intersection > 0) {
        return false;
    }
    const mask_union = info.red_mask | info.green_mask | info.blue_mask | info.alpha_mask;
    const type_overflow = ((@as(u32, @sizeOf(u32)) << 3) - @clz(mask_union)) > (@as(u32, @sizeOf(PixelIntType)) << 3);
    if (type_overflow) {
        return false;
    }
    return true;
}

fn getImageTags(
    info: *const BitmapInfo, color_table: *const BitmapColorTable, options: *const types.ImageLoadOptions
) !types.PixelTagPair {
    var tag_pair = types.PixelTagPair{};
    switch (info.compression) {
        .RGB, .BITFIELDS, .ALPHABITFIELDS => {
            if (info.color_depth <= 8) {
                tag_pair.in_tag = color_table.palette.activePixelTag();
            } else {
                const alpha_mask_present = info.alpha_mask > 0 and info.color_depth != 24;
                tag_pair.in_tag = switch (info.color_depth) {
                    16 => if (alpha_mask_present) .U16_RGBA else .U16_RGB,
                    24 => .U24_RGB,
                    32 => if (alpha_mask_present) .U32_RGBA else .U32_RGB,
                    else => .RGBA32,
                };
            }
        },
        .RLE4, .RLE8 => {
            tag_pair.in_tag = color_table.palette.activePixelTag();
        },
        else => {},
    }
    tag_pair.out_tag = try imagef.autoSelectImageFormat(tag_pair.in_tag, options);
    return tag_pair;
}

inline fn alignTo(comptime alignment: u29, num: u32) u32 {
    const negative_align = -@as(i32, @intCast(alignment));
    const signed_num = @as(i32, @intCast(num));
    return @as(u32, @bitCast((signed_num + (alignment - 1)) & negative_align));
}

// get row length in bytes as a multiple of 4 (rows are padded to 4 byte increments)
inline fn bmpRowSz(num: u32) u32 {
    return ((num + 31) & ~@as(u32, 31)) >> 3;
}

// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// ------------------------------------------------------------------------------------------------------------ creation
// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

fn createImage(
    buffer: []const u8, 
    image: *Image, 
    info: *BitmapInfo, 
    color_table: *const BitmapColorTable, 
    allocator: std.mem.Allocator,
    options: *const types.ImageLoadOptions
) !void {
    image.width = @intCast(@abs(info.width));
    image.height = @intCast(@abs(info.height));

    
    // basic check width & height information isn't corrupted
    const remain_sz_div4 = (buffer.len - info.data_offset) >> @as(u5, 2);
    if (image.width > remain_sz_div4 or image.height > remain_sz_div4) {
        if (info.compression != .RLE8 and info.compression != .RLE4) {
            return ImageError.BmpInvalidSizeInfo;
        }
    }
    if (image.width == 0 or image.height == 0) {
        return ImageError.BmpInvalidSizeInfo;
    }

    const row_sz = bmpRowSz(image.width * info.color_depth);
    const pixel_buf = buffer[info.data_offset..buffer.len];
    info.data_size = @intCast(buffer.len - info.data_offset);

    const format_pair = try getImageTags(info, color_table, options);

    const img_sz = @as(usize, @intCast(image.width)) * @as(usize, @intCast(image.height)) * format_pair.out_tag.size();
    if (img_sz > config.max_alloc_sz) {
        return ImageError.AllocTooLarge;
    }

    const alpha: imagef.ImageAlpha = 
        if (color_table.palette.isEmpty() and info.alpha_mask > 0 and info.color_depth == 32) imagef.ImageAlpha.Normal
        else .None;
    try image.init(allocator, format_pair.out_tag, image.width, image.height, alpha);
    image.file_info = types.ImageFileInfo{ .Bmp=info.* };

    try switch (info.compression) {
        .RGB => switch (info.color_depth) {
            inline 1, 4, 8, 16, 24, 32 => |val| {
                const IntType = imagef.bitCtToIntType(val);
                if (val <= 8) {
                    try transferColorTableImage(IntType, format_pair, pixel_buf, info, color_table, image, row_sz);
                } else {
                    try transferInlinePixelImage(IntType, format_pair, pixel_buf, info, image, row_sz, true);
                }
            },
            else => ImageError.BmpInvalidColorDepth,
        },
        inline .RLE4, .RLE8 => |format| {
            const IntType = if (format == .RLE4) u4 else u8;
            try transferRunLengthEncodedImage(
                IntType, format_pair, @as([*]const u8, @ptrCast(&pixel_buf[0])), info, color_table, image
            );
        },
        .BITFIELDS, .ALPHABITFIELDS => switch (info.color_depth) {
            inline 16, 32 => |val| {
                const IntType = imagef.bitCtToIntType(val);
                try transferInlinePixelImage(IntType, format_pair, pixel_buf, info, image, row_sz, false);
            },
            else => return ImageError.BmpInvalidCompression,
        },
        else => return ImageError.BmpCompressionUnsupported,
    };
}

fn transferColorTableImage(
    comptime IdxType: type, 
    format_pair: types.PixelTagPair,
    pixel_buf: []const u8, 
    info: *const BitmapInfo, 
    color_table: *const BitmapColorTable, 
    image: *Image, 
    row_sz: usize
) !void {
    if (color_table.palette.len() < 2) {
        return ImageError.BmpInvalidColorTable;
    }
    if (!bufferLongEnough(pixel_buf, image, row_sz)) {
        return ImageError.UnexpectedEndOfImageBuffer;
    }
    switch (format_pair.in_tag) {
        inline .RGBA32, .R8 => |in_tag| {
            switch (format_pair.out_tag) {
                inline .RGBA32, .RGB16, .R8, .R16 => |out_tag| {
                    try transferColorTableImageImpl(IdxType, in_tag, out_tag, pixel_buf, info, color_table, image, row_sz);
                },
                else => {}
            }
        },
        else => {},
    }
}

fn transferColorTableImageImpl(
    comptime IndexIntType: type,
    comptime in_tag: types.PixelTag,
    comptime out_tag: types.PixelTag,
    pixel_buf: []const u8,
    info: *const BitmapInfo,
    color_table: *const BitmapColorTable,
    image: *Image,
    row_sz: usize
) !void {
    const FilePixelType: type = in_tag.toType();
    const ImagePixelType: type = out_tag.toType();

    const colors: []const FilePixelType = try color_table.palette.getPixels(in_tag);
    var image_pixels: []ImagePixelType = try image.getPixels(out_tag);

    const direction_info = BitmapDirectionInfo.new(info, image.width, image.height);
    const row_byte_ct = bytesPerRow(IndexIntType, image.width);

    const transfer = try readerf.BitmapColorTransfer(in_tag, out_tag).standard(0);

    var px_row_start: usize = 0;
    for (0..image.height) |i| {
        const row_start: usize = @intCast(direction_info.begin + direction_info.increment * @as(i32, @intCast(i)));
        const row_end = row_start + image.width;

        const index_row: []const u8 = pixel_buf[px_row_start .. px_row_start + row_sz];
        const image_row: []ImagePixelType = image_pixels[row_start..row_end];

        // over each pixel (index to the color table) in the buffer row...
        try transfer.transferColorTableImageRow(IndexIntType, index_row, colors, image_row, row_byte_ct);
        
        px_row_start += row_sz;
    }
}

fn transferInlinePixelImage(
    comptime PixelIntType: type, 
    format_pair: types.PixelTagPair,
    pixel_buf: []const u8, 
    info: *const BitmapInfo, 
    image: *Image, 
    row_sz: usize, 
    standard_masks: bool
) !void {
    var alpha_mask_present = info.compression == .ALPHABITFIELDS or info.alpha_mask > 0;
    if (!bufferLongEnough(pixel_buf, image, row_sz)) {
        return ImageError.UnexpectedEndOfImageBuffer;
    }
    if (!standard_masks or alpha_mask_present) {
        if (PixelIntType == u24) {
            alpha_mask_present = false;
        }
        if (!validColorMasks(PixelIntType, info)) {
            return ImageError.BmpInvalidColorMasks;
        }
    }
    switch (format_pair.in_tag) {
        inline .U32_RGBA, .U32_RGB, .U24_RGB, .U16_RGBA, .U16_RGB => |in_tag| {
            switch (format_pair.out_tag) {
                inline .RGBA32, .RGB16, .R8, .R16 => |out_tag| {
                    try transferInlinePixelImageImpl(in_tag, out_tag, info, pixel_buf, image, row_sz, standard_masks);
                },
                else => {}
            }
        },
        else => {},
    }
}

fn transferInlinePixelImageImpl(
    comptime in_tag: types.PixelTag,
    comptime out_tag: types.PixelTag,
    info: *const BitmapInfo,
    pixel_buf: []const u8, 
    image: *Image, 
    row_sz: usize, 
    standard_masks: bool
) !void {
    const ImagePixelType: type = out_tag.toType();
    var image_pixels: []ImagePixelType = try image.getPixels(out_tag);

    const transfer = 
        if (standard_masks) try readerf.BitmapColorTransfer(in_tag, out_tag).standard(info.alpha_mask)
        else try readerf.BitmapColorTransfer(in_tag, out_tag).fromInfo(info);

    const direction_info = BitmapDirectionInfo.new(info, image.width, image.height);
    var px_start: usize = 0;
    for (0..image.height) |i| {
        const img_start: usize = @intCast(direction_info.begin + direction_info.increment * @as(i32, @intCast(i)));
        const img_end = img_start + image.width;

        const buffer_row: [*]const u8 = @ptrCast(&pixel_buf[px_start]);
        const image_row: []ImagePixelType = image_pixels[img_start..img_end];

        transfer.transferRowFromBytes(buffer_row, image_row);

        px_start += row_sz;
    }
}

fn transferRunLengthEncodedImage(
    comptime IndexIntType: type,
    format_pair: types.PixelTagPair,
    pbuf: [*]const u8,
    info: *const BitmapInfo,
    color_table: *const BitmapColorTable,
    image: *Image,
) !void {
    if (color_table.palette.len() < 2) {
        return ImageError.BmpInvalidColorTable;
    }
    if (info.color_depth != rle_bit_sizes[@intFromEnum(info.compression)]) {
        return ImageError.BmpInvalidCompression;
    }
    switch (format_pair.in_tag) {
        inline .RGBA32, .R8, => |in_tag| {
            switch (format_pair.out_tag) {
                inline .RGBA32, .RGB16, .R8, .R16 => |out_tag| {
                    try transferRunLengthEncodedImageImpl(
                        IndexIntType, in_tag, out_tag, pbuf, info, color_table, image
                    );
                },
                else => {}
            }
        },
        else => {},
    }
}


// // bmps can have a form of compression, RLE, which does the simple trick of encoding repeating pixels via
// // a number n (repeat ct) and pixel p in contiguous bytes. 
fn transferRunLengthEncodedImageImpl(
    comptime IndexIntType: type,
    comptime in_tag: types.PixelTag,
    comptime out_tag: types.PixelTag,
    pbuf: [*]const u8,
    info: *const BitmapInfo,
    color_table: *const BitmapColorTable,
    image: *Image,
) !void {
    var reader = try BmpRLEReader(IndexIntType, in_tag, out_tag).new(image.width, image.height);

    var i: usize = 0;
    const iter_max: usize = image.width * image.height;
    // the compiler is giving me garbage on the passed-in pbuf (as slice) and the only fix I found is to take a slice of
    // pbuf (as ptr) s.t. the result is exactly what pbuf should be.
    const pixel_buf = pbuf[0..info.data_size];

    while (i < iter_max) : (i += 1) {
        const action = try reader.readAction(pixel_buf);
        switch (action) {
            .ReadPixels =>      try reader.readPixels(pixel_buf, color_table, image),
            .RepeatPixels =>    try reader.repeatPixel(color_table, image),
            .Move =>            try reader.changeCoordinates(pixel_buf),
            .EndRow =>          reader.incrementRow(),
            .EndImage =>        break,
        }
    }
}

// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// ----------------------------------------------------------------------------------------------------------- constants
// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

const bmp_file_header_sz = 14;
const bmp_info_header_sz_core = 12;
const bmp_info_header_sz_v1 = 40;
const bmp_info_header_sz_v4 = 108;
const bmp_info_header_sz_v5 = 124;
const bmp_row_align = 4; // bmp pixel rows pad to 4 bytes
const bmp_rgb24_sz = 3;
// the smallest possible (hard disk) bmp has a core header, 1 bit px sz (2 colors in table), width in [1,32] and height = 1
const bmp_min_sz = bmp_file_header_sz + bmp_info_header_sz_core + 2 * bmp_rgb24_sz + bmp_row_align;

const rle_bit_sizes: [3]u32 = .{ 0, 8, 4 };

// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// --------------------------------------------------------------------------------------------------------------- enums
// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

const BitmapHeaderType = enum(u32) { None, Core, V1, V4, V5 };

pub const BitmapCompression = enum(u32) { 
    RGB, RLE8, RLE4, BITFIELDS, JPEG, PNG, ALPHABITFIELDS, CMYK, CMYKRLE8, CMYKRLE4, None 
};

const BitmapReadDirection = enum(u8) { BottomUp = 0, TopDown = 1 };

pub const BitmapColorSpace = enum(u32) {
    CalibratedRGB = 0x0,
    ProfileLinked = 0x4c494e4b,
    ProfileEmbedded = 0x4d424544,
    WindowsCS = 0x57696e20,
    sRGB = 0x73524742,
    None = 0xffffffff,
};

// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// --------------------------------------------------------------------------------------------------------------- types
// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// extern to preserve order
pub const BitmapInfo = extern struct {
    file_sz: u32 = 0,
    // offset from beginning of file to pixel data
    data_offset: u32 = 0,
    // size of the info header (comes after the file header)
    header_sz: u32 = 0,
    header_type: BitmapHeaderType = .None,
    width: i32 = 0,
    height: i32 = 0,
    // bits per pixel
    color_depth: u32 = 0,
    compression: BitmapCompression = .None,
    // pixel data size; may not always be valid.
    data_size: u32 = 0,
    // how many colors in image. mandatory for color depths of 1,4,8. if 0, using full color depth.
    color_ct: u32 = 0,
    // masks to pull color data from pixels. only used if compression is BITFIELDS or ALPHABITFIELDS
    red_mask: u32 = 0x0,
    green_mask: u32 = 0x0,
    blue_mask: u32 = 0x0,
    alpha_mask: u32 = 0x0,
    // how the colors should be interpreted
    color_space: BitmapColorSpace = .None,
    // if using a color space profile, info about how to interpret colors
    profile_data: u32 = undefined,
    profile_size: u32 = undefined,
    // triangle representing the color space of the image
    cs_points: CieXYZTriple = undefined,
    // function f takes two parameters: 1.) gamma and 2.) a color value c in, for example, 0 to 255. It outputs
    // a color value f(gamma, c) in 0 and 255, on a concave curve. larger gamma -> more concave.
    red_gamma: u32 = 0,
    green_gamma: u32 = 0,
    blue_gamma: u32 = 0,
};

const FxPt2Dot30 = extern struct {
    data: u32 = 0,

    pub inline fn integer(self: *const FxPt2Dot30) u32 {
        return (self.data & 0xc0000000) >> 30;
    }

    pub inline fn fraction(self: *const FxPt2Dot30) u32 {
        return self.data & 0x3fffffff;
    }
};

pub const BitmapColorTable = struct {
    buffer: [1024]u8 align(@alignOf(types.BGR32)) = undefined,
    palette: Image = Image{},
};

const CieXYZTriple = extern struct {
    red: [3]FxPt2Dot30 = .{FxPt2Dot30{}, FxPt2Dot30{}, FxPt2Dot30{}},
    green: [3]FxPt2Dot30 = .{FxPt2Dot30{}, FxPt2Dot30{}, FxPt2Dot30{}},
    blue: [3]FxPt2Dot30 = .{FxPt2Dot30{}, FxPt2Dot30{}, FxPt2Dot30{}},
};

const BitmapDirectionInfo = struct {
    begin: i32,
    increment: i32,

    // bitmaps are stored bottom to top, meaning the top-left corner of the image is idx 0 of the last row, unless the
    // height param is negative. we always read top to bottom and write up or down depending.
    fn new(info: *const BitmapInfo, width: u32, height: u32) BitmapDirectionInfo {
        const write_direction: BitmapReadDirection = @enumFromInt(@as(u8, @intFromBool(info.height < 0)));
        if (write_direction == .BottomUp) {
            return BitmapDirectionInfo{
                .begin = (@as(i32, @intCast(height)) - 1) * @as(i32, @intCast(width)),
                .increment = -@as(i32, @intCast(width)),
            };
        } else {
            return BitmapDirectionInfo{
                .begin = 0,
                .increment = @as(i32, @intCast(width)),
            };
        }
    }
};

