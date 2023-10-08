const std = @import("std");
const imagef = @import("image.zig");
const string = @import("../utils/string.zig");
const readerf = @import("reader.zig");
const types = @import("types.zig");
const config = @import("config.zig");

const LocalBuffer = @import("../utils/localbuffer.zig").LocalBuffer;
const Image = types.Image;
const ImageError = imagef.ImageError;
const print = std.debug.print;
const ARGB64 = types.ARGB64;
const ImageAlpha = imagef.ImageAlpha;
const BitmapColorMaskSet = readerf.InlinePixelReader;
const TgaReadInfo = readerf.TgaReadInfo;
const TgaRLEReader = readerf.TgaRLEReader;

// TODO: test images for color correction table

/// - Color Types
///     - PsuedoColor: pixels are indices to a color table/map
///     - TrueColor: pixels are subdivided into rgb fields
///     - DirectColor: pixels are subdivided into r, g, and b indices to independent color table entries defining intensity
/// - TGA files are little-endian

pub fn load(
    file: *std.fs.File, image: *Image, allocator: std.mem.Allocator, options: *const types.ImageLoadOptions
) !void {
    var info = TgaInfo{};
    var extents = ExtentBuffer.new();
    defer freeAllocations(&info, allocator);

    try readFooter(file, &info, &extents);
    if (!readHeader(file, &info, &extents)) {
        try imagef.redirectLoad(file, image, allocator, options, imagef.ImageFormat.Tga);
        return;
    }
    try readExtensionData(file, &info, allocator, &extents);
    try readImageId(file, &info, &extents);

    var buffer: []align(4) u8 = try loadColorMapAndImageData(file, &info, allocator, &extents);
    defer allocator.free(buffer);

    try createImage(&info, image, allocator, buffer, options);
}

fn readFooter(file: *std.fs.File, info: *TgaInfo, extents: *ExtentBuffer) !void {
    const stat = try file.stat();
    if (stat.size > config.max_alloc_sz) {
        return ImageError.AllocTooLarge;
    }

    info.file_sz = @intCast(stat.size);
    if (info.file_sz < tga_min_sz) {
        return ImageError.InvalidSizeForFormat;
    }

    const footer_begin: u32 = info.file_sz - footer_end_offset;
    try file.seekTo(footer_begin);
    info.footer = try file.reader().readStruct(TgaFooter);

    if (string.same(info.footer.?.signature[0..], imagef.tga_identifier)) {
        info.file_type = TgaFileType.V2;
        extents.append(BlockExtent{ .begin=footer_begin, .end=info.file_sz });
    } else {
        info.file_type = TgaFileType.V1;
        info.footer = null;
    }
}

fn readHeader(file: *std.fs.File, info: *TgaInfo, extents: *ExtentBuffer) bool {
    try validateAndAddExtent(extents, info, 0, tga_header_sz);
    // reading three structs rather than one so we're not straddling boundaries on any of the data.
    try file.seekTo(0);
    info.header.info = file.reader().readStruct(TgaHeaderInfo) catch return false;
    info.header.colormap_spec = file.reader().readStruct(TgaColorMapSpec) catch return false;
    // colormap_spec has 1 byte padding
    try file.seekTo(tga_image_spec_offset);
    info.header.image_spec = file.reader().readStruct(TgaImageSpec) catch return false;
    if (!typeSupported(info.header.info.image_type)) {
        return false;
    }
}

fn readExtensionData(file: *std.fs.File, info: *TgaInfo, allocator: std.mem.Allocator, extents: *ExtentBuffer) !void {
    if (info.footer == null) {
        return;
    }

    const extension_area_begin = info.footer.?.extension_area_offset;
    const extension_area_end = extension_area_begin + extension_area_file_sz;
    if (extension_area_begin == 0 or extension_area_end > info.file_sz) {
        return;
    }

    try file.seekTo(extension_area_begin);
    info.extension_area = ExtensionArea{};
    info.extension_area.?.extension_sz = try file.reader().readIntLittle(u16);

    if (extension_area_begin + info.extension_area.?.extension_sz > info.file_sz
        or info.extension_area.?.extension_sz != extension_area_file_sz
    ) {
        info.extension_area = null;
        return;
    }

    try validateAndAddExtent(extents, info, extension_area_begin, extension_area_end);
    try readExtensionArea(file, info);

    const alpha_identifier = info.extension_area.?.attributes_type;
    const colormap_spec = info.header.colormap_spec;
    const image_spec = info.header.image_spec;

    if (alpha_identifier == 3 and (image_spec.color_depth == 32 or colormap_spec.entry_bit_ct == 32)) {
        info.alpha = .Normal;
    } else if (alpha_identifier == 4) {
        info.alpha = .Premultiplied;
    }

    if (info.extension_area.?.scanline_offset != 0) {
        info.scanline_table = try loadTable(
            file, info, allocator, extents, info.extension_area.?.scanline_offset, u32, info.header.image_spec.image_height
        );
    }
    if (info.extension_area.?.postage_stamp_offset != 0) {
        // TODO: read postage stamp. uses same format as image
    }
    if (info.extension_area.?.color_correction_offset != 0) {
        info.color_correction_table = try loadTable(
            file, info, allocator, extents, info.extension_area.?.color_correction_offset, ARGB64, 256
        );
    }
}

fn readExtensionArea(file: *std.fs.File, info: *TgaInfo) !void {
    const extbuf: [493]u8 = try file.reader().readBytesNoEof(493);
    info.extension_area.?.author_name = extbuf[0..41].*;
    info.extension_area.?.author_comments = extbuf[41..365].*;
    const timestamp_ptr: [*]const u16 = @ptrCast(@alignCast(&extbuf[365]));
    // const timestamp_slice: []const u16 = timestamp_ptr[0..6];
    @memcpy(info.extension_area.?.timestamp[0..6], timestamp_ptr[0..6]);
    // info.extension_area.?.timestamp = 
    info.extension_area.?.job_name = extbuf[377..418].*;
    inline for(0..3) |i| {
        info.extension_area.?.job_time[i] = std.mem.readIntLittle(u16, extbuf[418+(i*2)..420+(i*2)]);
    }
    info.extension_area.?.software_id = extbuf[424..465].*;
    info.extension_area.?.software_version = extbuf[465..468].*;
    info.extension_area.?.key_color = std.mem.readIntLittle(u32, extbuf[468..472]);
    inline for(0..2) |i| {
        info.extension_area.?.pixel_aspect_ratio[i] = std.mem.readIntLittle(u16, extbuf[472+(i*2)..474+(i*2)]);
    }
    inline for(0..2) |i| {
        info.extension_area.?.gamma[i] = std.mem.readIntLittle(u16, extbuf[476+(i*2)..478+(i*2)]);
    }
    info.extension_area.?.color_correction_offset = std.mem.readIntLittle(u32, extbuf[480..484]);
    info.extension_area.?.postage_stamp_offset = std.mem.readIntLittle(u32, extbuf[484..488]);
    info.extension_area.?.scanline_offset = std.mem.readIntLittle(u32, extbuf[488..492]);
    info.extension_area.?.attributes_type = extbuf[492];
}

fn loadTable(
    file: *std.fs.File, 
    info: *TgaInfo, 
    allocator: std.mem.Allocator, 
    extents: *ExtentBuffer, 
    offset: u32, 
    comptime TableType: type,
    table_ct: u32
) ![]TableType {
    const sz = @sizeOf(TableType) * table_ct;
    const end = offset + sz;
    try validateAndAddExtent(extents, info, offset, end);

    var table: []TableType = try allocator.alloc(TableType, table_ct);
    var bytes_ptr: [*]u8 = @ptrCast(@alignCast(&table[0]));

    try file.seekTo(offset);
    try file.reader().readNoEof(bytes_ptr[0..sz]);
    
    return table;
}

fn readImageId(file: *std.fs.File, info: *TgaInfo, extents: *ExtentBuffer) !void {
    if (info.header.info.id_length == 0) {
        return;
    }

    const id_begin = tga_header_sz;
    const id_end = id_begin + info.header.info.id_length;
    try validateAndAddExtent(extents, info, id_begin, id_end); 

    try file.seekTo(tga_header_sz);
    try file.reader().readNoEof(info.id[0..info.header.info.id_length]);
}

pub fn typeSupported(image_type: TgaImageType) bool {
    return switch(image_type) {
        .NoData => false,
        .ColorMap => true,
        .TrueColor => true,
        .Greyscale => true,
        .RleColorMap => true,
        .RleTrueColor => true,
        .RleGreyscale => true,
        .HuffmanDeltaRleColorMap => false,
        .HuffmanDeltaRleQuadtreeColorMap => false,
    };
}

fn loadColorMapAndImageData(
    file: *std.fs.File, 
    info: *TgaInfo, 
    allocator: std.mem.Allocator,
    extents: *ExtentBuffer
) ![]align(4) u8 {
    const image_type = info.header.info.image_type;
    const image_spec = info.header.image_spec;
    const colormap_spec = info.header.colormap_spec;

    var ct_start: u32 = tga_header_sz + info.header.info.id_length;
    var ct_end: u32 = ct_start;
    switch(image_type) {
        .NoData, .TrueColor, .Greyscale, .RleTrueColor, .RleGreyscale => {
            if (colormap_spec.entry_bit_ct != 0
                or colormap_spec.first_idx != 0
                or colormap_spec.len != 0
            ) {
                return ImageError.TgaColorMapDataInNonColorMapImage;
            }
        },
        .ColorMap, .RleColorMap => {
            info.color_map.step_sz = try switch(colormap_spec.entry_bit_ct) {
                15, 16 => @as(u32, 2),
                24 => @as(u32, 3),
                32 => @as(u32, 4),
                else => ImageError.TgaNonStandardColorTableUnsupported,
            };
            ct_end = ct_start + info.color_map.step_sz * colormap_spec.len;
        },
        else => unreachable,
    }
    info.color_map.buffer_sz = ct_end - ct_start;

    switch (image_spec.color_depth) {
        8, 15, 16, 24, 32 => {},
        else => return ImageError.TgaNonStandardColorDepthUnsupported,
    }

    const img_start: u32 = ct_end;
    const img_end: u32 = findImageEnd(info, extents);
    if (img_start >= img_end) {
        return ImageError.TgaNoData;
    }

    try validateAndAddExtent(extents, info, ct_start, img_end);
    
    var buffer: []align(4) u8 = try allocator.alignedAlloc(u8, 4, img_end - ct_start);
    try file.seekTo(ct_start);

    if (info.color_map.buffer_sz > 0) {
        try file.reader().readNoEof(buffer[0..info.color_map.buffer_sz]);
        try readColorMapData(info, allocator, buffer);
    }
    const img_buffer_sz = buffer.len - info.color_map.buffer_sz;
    try file.reader().readNoEof(buffer[0..img_buffer_sz]);
    return buffer;
}

fn findImageEnd(info: *const TgaInfo, extents: *const ExtentBuffer) u32 {
    var start_extent: usize = undefined;
    if (info.header.info.id_length == 0) {
        start_extent = 0;
    } else {
        start_extent = 1;
    }
    if (extents.len > start_extent + 1) {
        return extents.buffer[start_extent+1].begin;
    } else {
        return info.file_sz;
    }
}

fn readColorMapData(info: *TgaInfo, allocator: std.mem.Allocator, buffer: []const u8) !void {
    if (info.color_map.buffer_sz == 0) {
        return;
    }
    const cm_spec = info.header.colormap_spec;
    info.color_map.table = try allocator.alloc(types.RGBA32, cm_spec.len);

    var i: usize = 0;
    var offset: usize = 0;
    while (offset < info.color_map.buffer_sz) {
        var entry: *types.RGBA32 = &info.color_map.table.?[i];
        switch (cm_spec.entry_bit_ct) {
            15 => {
                const color: u16 = std.mem.readIntSliceLittle(u16, buffer[offset..offset+2]);
                entry.r = @intCast((color & 0x7c00) >> 7);
                entry.g = @intCast((color & 0x03e0) >> 3);
                entry.b = @intCast((color & 0x001f) << 3);
                entry.a = 255;
            }, 16 => {
                const color: u16 = std.mem.readIntSliceLittle(u16, buffer[offset..offset+2]);
                entry.r = @intCast((color & 0xf800) >> 8);
                entry.g = @intCast((color & 0x07e0) >> 3);
                entry.b = @intCast((color & 0x001f) << 3);
                entry.a = 255;
            }, 24 => {
                entry.b = buffer[offset];
                entry.g = buffer[offset+1];
                entry.r = buffer[offset+2];
                entry.a = 255;
            }, 32 => {
                entry.b = buffer[offset];
                entry.g = buffer[offset+1];
                entry.r = buffer[offset+2];
                entry.a = buffer[offset+3];
            }, else => unreachable,
        }
        offset += info.color_map.step_sz;
        i += 1;
    }
}

fn getImageTags(
    info: *const TgaInfo, options: *const types.ImageLoadOptions
) !types.PixelTagPair {
    var tag_pair = types.PixelTagPair{};
    const color_depth = info.header.image_spec.color_depth;
    const image_type = info.header.info.image_type;

    switch (image_type) {
        .TrueColor, .RleTrueColor => {
            tag_pair.in_tag = switch(color_depth) {
                15 => types.PixelTag.U16_RGB15, 
                16 => types.PixelTag.U16_RGB,
                24 => types.PixelTag.U24_RGB,
                32 => if (info.alpha == .Normal) types.PixelTag.U32_RGBA else types.PixelTag.U32_RGB,
                else => return ImageError.TgaNonStandardColorDepthUnsupported,
            };
        },
        .Greyscale, .RleGreyscale => {
            tag_pair.in_tag = switch(color_depth) {
                8 => types.PixelTag.U8_R,
                15, 16 => types.PixelTag.U16_R,
                else => return ImageError.TgaNonStandardColorDepthUnsupported,
            };
        },
        .ColorMap, .RleColorMap => {
            tag_pair.in_tag = switch(color_depth) {
                8 => types.PixelTag.RGBA32,
                else => return ImageError.TgaColorTableImageNot8BitColorDepth,
            };
        },
        else => {},
    }

    tag_pair.out_tag = try imagef.autoSelectImageFormat(tag_pair.in_tag, options);
    return tag_pair;
}

fn createImage(
    info: *const TgaInfo, 
    image: *Image, 
    allocator: std.mem.Allocator, 
    buffer: []const u8,
    options: *const types.ImageLoadOptions,
) !void {
    const image_spec = info.header.image_spec;
    const pixel_ct: usize = @as(u32, @intCast(image_spec.image_width)) * @as(u32, @intCast(image_spec.image_height));
    const file_image_sz = pixel_ct * (image_spec.color_depth >> 3);
    const image_type: TgaImageType = info.header.info.image_type;
    if (file_image_sz > buffer.len 
        and image_type != .RleColorMap 
        and image_type != .RleTrueColor 
        and image_type != .RleGreyscale
    ) {
        return ImageError.UnexpectedEndOfImageBuffer;
    }

    const format_tags: types.PixelTagPair = try getImageTags(info, options);
    const image_sz: usize = @as(usize, @intCast(image_spec.image_width)) 
        * @as(usize, @intCast(image_spec.image_height))
        * format_tags.out_tag.size();

    if (image_sz > config.max_alloc_sz) {
        return ImageError.AllocTooLarge;
    }

    try image.init(allocator, format_tags.out_tag, image_spec.image_width, image_spec.image_height, info.alpha);

    const bufptr = @as([*]const u8, @ptrCast(&buffer[0]));
    switch (info.header.info.image_type) {
        .TrueColor, .Greyscale => switch(image_spec.color_depth) {
            inline 8, 15, 16, 24, 32 => |depth| {
                const IntType = imagef.bitCtToIntType(depth);
                try readInlinePixelImage(IntType, format_tags, info, image, bufptr);
            }, else => return ImageError.TgaNonStandardColorDepthForPixelFormat,
        },
        .ColorMap => try switch(image_spec.color_depth) {
            8 => readColorMapImage(u8, format_tags, info, image, bufptr),
            else => return ImageError.TgaNonStandardColorDepthForPixelFormat,
        },
        .RleColorMap => try switch(image_spec.color_depth) {
            8 => readRunLengthEncodedImage(u8, true, format_tags, info, image, bufptr),
            else => return ImageError.TgaNonStandardColorDepthForPixelFormat,
        },
        .RleTrueColor, .RleGreyscale => switch(image_spec.color_depth) {
            inline 8, 15, 16, 24, 32 => |depth| {
                const IntType = imagef.bitCtToIntType(depth);
                try readRunLengthEncodedImage(IntType, false, format_tags, info, image, bufptr);
            }, else => return ImageError.TgaNonStandardColorDepthForPixelFormat,
        },
        else => return ImageError.TgaFlavorUnsupported,
    }
}

fn freeAllocations(info: *TgaInfo, allocator: std.mem.Allocator) void {
    if (info.scanline_table != null) {
        allocator.free(info.scanline_table.?);
    }
    if (info.postage_stamp_table != null) {
        allocator.free(info.postage_stamp_table.?);
    }
    if (info.color_correction_table != null) {
        allocator.free(info.color_correction_table.?);
    }
    if (info.color_map.table != null) {
        allocator.free(info.color_map.table.?);
    }
}

fn validateAndAddExtent(extents: *ExtentBuffer, info: *const TgaInfo, begin: u32, end: u32) !void {
    if (end > info.file_sz) {
        return ImageError.UnexpectedEOF;
    }
    if (extentOverlap(extents, begin, end)) {
        return ImageError.OverlappingData;
    }
    extents.compareInsert(BlockExtent{ .begin=begin, .end=end });
}

fn extentOverlap(extents: *const ExtentBuffer, begin: u32, end: u32) bool {
    for (extents.*.constItems()) |extent| {
        if ((begin >= extent.begin and begin < extent.end)
            or (end > extent.begin and end <= extent.end)
        ) {
            return true;
        }
    }
    return false;
}

fn readInlinePixelImage(
    comptime PixelIntType: type, 
    format_pair: types.PixelTagPair, 
    info: *const TgaInfo, 
    image: *Image, 
    buffer: [*]const u8, 
) !void {
    switch(format_pair.in_tag) {
        inline .U32_RGB, .U32_RGBA, .U24_RGB, .U16_RGB, .U16_RGB15, .U8_R, .U16_R => |in_tag| {
            switch(format_pair.out_tag) {
                inline .RGBA32, .RGB16, .R8, .R16 => |out_tag| {
                    try readInlinePixelImageImpl(PixelIntType, in_tag, out_tag, info, image, buffer);
                }, else => unreachable,
            }
        }, else => unreachable,
    }
}

fn readInlinePixelImageImpl(
    comptime PixelIntType: type, 
    comptime in_tag: types.PixelTag,
    comptime out_tag: types.PixelTag,
    info: *const TgaInfo, 
    image: *Image, 
    buffer: [*]const u8
) !void {
    const alpha_mask = if (PixelIntType == u32) 0xff000000 else 0;

    const transfer = try readerf.BitmapColorTransfer(in_tag, out_tag).standard(alpha_mask);
    var read_info = try TgaReadInfo(PixelIntType).new(info, image);

    const ImagePixelType: type = out_tag.toType();
    var image_pixels: []ImagePixelType = try image.getPixels(out_tag);

    while (read_info.read_start < read_info.image_sz) {
        const read_end: i32 = read_info.read_start + read_info.read_row_step;
        const write_end: i32 = read_info.write_start + @as(i32, @intCast(image.width));

        if (write_end < 0 or write_end > image_pixels.len or read_end < 0 or read_end > read_info.image_sz) {
            return ImageError.UnexpectedEndOfImageBuffer;
        }

        var file_row: [*]const u8 = @ptrCast(&buffer[@intCast(read_info.read_start)]);
        var image_row = image_pixels[@intCast(read_info.write_start)..@intCast(write_end)];

        transfer.transferRowFromBytes(file_row, image_row);

        read_info.read_start += read_info.read_row_step;
        read_info.write_start += read_info.write_row_step;
    }
}

fn readColorMapImage(
    comptime IndexIntType: type, 
    format_pair: types.PixelTagPair, 
    info: *const TgaInfo, 
    image: *Image, 
    buffer: [*]const u8
) !void {
    switch(format_pair.out_tag) {
        inline .RGBA32, .RGB16, .R8, .R16 => |out_tag| {
            try readColorMapImageImpl(IndexIntType, types.PixelTag.RGBA32, out_tag, info, image, buffer);
        }, else => unreachable,
    }
}

fn readColorMapImageImpl(
    comptime IndexIntType: type,
    comptime in_tag: types.PixelTag,
    comptime out_tag: types.PixelTag,
    info: *const TgaInfo, 
    image: *Image, 
    buffer: [*]const u8, 
) !void {

    const transfer = try readerf.BitmapColorTransfer(in_tag, out_tag).standard(0xff000000);
    var read_info = try TgaReadInfo(IndexIntType).new(info, image);

    const ImagePixelType: type = out_tag.toType();
    var image_pixels: []ImagePixelType = try image.getPixels(out_tag);

    while (read_info.read_start < read_info.image_sz) {
        const read_end: i32 = read_info.read_start + read_info.read_row_step;
        const write_end: i32 = read_info.write_start + @as(i32, @intCast(image.width));

        if (write_end < 0 or write_end > image_pixels.len or read_end < 0 or read_end > read_info.image_sz) {
            return ImageError.UnexpectedEndOfImageBuffer;
        }

        var index_row = buffer[@intCast(read_info.read_start)..@intCast(read_end)];
        var image_row = image_pixels[@intCast(read_info.write_start)..@intCast(write_end)];

        try transfer.transferColorTableImageRow(
            IndexIntType, index_row, info.color_map.table.?, image_row, @intCast(read_info.read_row_step)
        );

        read_info.read_start += read_info.read_row_step;
        read_info.write_start += read_info.write_row_step;
    }
}

fn readRunLengthEncodedImage(
    comptime InlineIntType: type, 
    comptime color_table_img: bool, 
    format_pair: types.PixelTagPair, 
    info: *const TgaInfo,
    image: *Image,
    buffer: [*]const u8,
) !void {
    switch(format_pair.in_tag) {
        inline .RGBA32, .U32_RGB, .U32_RGBA, .U24_RGB, .U16_RGB, .U16_RGB15, .U8_R, .U16_R => |in_tag| {
            switch(format_pair.out_tag) {
                inline .RGBA32, .RGB16, .R8, .R16 => |out_tag| {
                    try readRunLengthEncodedImageImpl(
                        InlineIntType, color_table_img, in_tag, out_tag, info, image, buffer
                    );
                }, else => unreachable,
            }
        }, else => unreachable,
    }
}

fn readRunLengthEncodedImageImpl(
    comptime InlineIntType: type, 
    comptime color_table_img: bool,
    comptime in_tag: types.PixelTag,
    comptime out_tag: types.PixelTag,
    info: *const TgaInfo, 
    image: *Image, 
    buffer: [*]const u8, 
) !void {
    var reader = try TgaRLEReader(InlineIntType, color_table_img, in_tag, out_tag).new(info, image);

    var i: usize = 0;
    const iter_max: usize = image.width * image.height;
    const pixel_buf = buffer[0..@intCast(reader.read_info.image_sz)];

    while (i < iter_max) : (i += 1) {
        const action = try reader.readAction(image, info, pixel_buf);
        switch (action) {
            .ReadPixels =>      try reader.readPixels(pixel_buf, info, image),
            .RepeatPixels =>    try reader.repeatPixel(image),
            .EndImage =>        break,
            else =>             unreachable,
        }
    }
}

pub const TgaImageType = enum(u8) {
    NoData = 0,
    ColorMap = 1,
    TrueColor = 2,
    Greyscale = 3,
    RleColorMap = 9,
    RleTrueColor = 10,
    RleGreyscale = 11,
    HuffmanDeltaRleColorMap = 32,
    HuffmanDeltaRleQuadtreeColorMap = 33,
};

const TgaColorMapSpec = extern struct {
    first_idx: u16,
    len: u16,
    entry_bit_ct: u8,
};

pub const TgaImageSpec = extern struct {
    origin_x: u16,
    origin_y: u16,
    image_width: u16,
    image_height: u16,
    color_depth: u8,
    descriptor: u8
};

const TgaHeaderInfo = extern struct {
    id_length: u8,
    color_map_type: u8,
    image_type: TgaImageType,
};

const TgaHeader = extern struct {
    info: TgaHeaderInfo,
    colormap_spec: TgaColorMapSpec,
    image_spec: TgaImageSpec,
};

const ExtensionArea = extern struct {
    extension_sz: u16 = 0,
    author_name: [41]u8 = undefined,
    author_comments: [324]u8 = undefined,
    timestamp: [6]u16 = undefined,
    job_name: [41]u8 = undefined,
    job_time: [3]u16 = undefined,
    software_id: [41]u8 = undefined,
    software_version: [3]u8 = undefined,
    key_color: u32 = undefined,
    pixel_aspect_ratio: [2]u16 = undefined,
    gamma: [2]u16 = undefined,
    color_correction_offset: u32 = undefined,
    postage_stamp_offset: u32 = undefined,
    scanline_offset: u32 = undefined,
    attributes_type: u8 = undefined,
};

pub const TgaFooter = extern struct {
    extension_area_offset: u32,
    developer_directory_offset: u32,
    signature: [16]u8
};

const TgaColorMap = struct {
    buffer_sz: u32 = 0,
    step_sz: u32 = 0,
    table: ?[]types.RGBA32 = null,
};

pub const TgaInfo = struct {
    id: [256]u8 = std.mem.zeroes([256]u8),
    file_type: TgaFileType = .None,
    file_sz: u32 = 0,
    header: TgaHeader = undefined,
    extension_area: ?ExtensionArea = null,
    footer: ?TgaFooter = null,
    scanline_table: ?[]u32 = null,
    postage_stamp_table: ?[]u8 = null,
    color_correction_table: ?[]ARGB64 = null,
    color_map: TgaColorMap = TgaColorMap{},
    alpha: ImageAlpha = .None,
};

const BlockExtent = struct {
    begin: u32,
    end: u32,

    pub fn compare(self: *const BlockExtent, other: BlockExtent) bool {
        return self.begin < other.begin;
    }
};

const TgaFileType = enum(u8) { None, V1, V2 };
const ExtentBuffer = LocalBuffer(BlockExtent, 10);

const tga_header_sz = 18;
const tga_image_spec_offset = 8;
const tga_min_sz = @sizeOf(TgaHeader);
pub const footer_end_offset = @sizeOf(TgaFooter) + 2;
const extension_area_file_sz = 495;
const color_correction_table_sz = @sizeOf(ARGB64) * 256;