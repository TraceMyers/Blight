const std = @import("std");
const tga = @import("tga.zig");
const types = @import("types.zig");

const BitmapInfo = @import("bmp.zig").BitmapInfo;
const BitmapColorTable = @import("bmp.zig").BitmapColorTable;
const imagef = @import("image.zig");
const Image = imagef.Image;
const ImageError = imagef.ImageError;
const ImageAlpha = types.ImageAlpha;
const TgaImageSpec = tga.TgaImageSpec;
const TgaInfo = tga.TgaInfo;
const RGBA32 = types.RGBA32;

pub const RLEAction = enum {
    EndRow, // 0
    EndImage, // 1
    Move, // 2
    ReadPixels, // 3
    RepeatPixels, // 4
};

fn BitmapComponentMask (comptime InPixelIntType: type, comptime ImagePixelComponentType: type) type {

    const ShiftType = switch (InPixelIntType) {
        u8 => u4,
        u16 => u4,
        u24 => u5,
        u32 => u5,
        else => u8,
    };

    return struct {
        const MaskType = @This();

        mask: InPixelIntType = 0,
        rshift: ShiftType = 0,
        lshift: ShiftType = 0,
        rshift_u8: ShiftType = 0,
        lshift_u8: ShiftType = 0,

        fn new(in_mask: u32) !MaskType {
            if (in_mask == 0) {
                return MaskType{};
            }
            const mask_leading_zeroes: i32 = @intCast(@clz(in_mask));
            const mask_trailing_zeroes: i32 = @intCast(@ctz(in_mask));
            const mask_bit_ct = 32 - (mask_leading_zeroes + mask_trailing_zeroes);
            const component_bit_ct: i32 = switch (ImagePixelComponentType) {
                u1 => 1,
                u5 => 5,
                u6 => 6,
                u8 => 8,
                u16 => 16,
                else => unreachable,
            };
            const rshift: i32 = mask_trailing_zeroes - (component_bit_ct - mask_bit_ct);
            const rshift_u8: i32 = mask_trailing_zeroes - (8 - mask_bit_ct);

            if (rshift > 0) {
                if (rshift_u8 > 0) {
                    return MaskType{ 
                        .mask = @intCast(in_mask), 
                        .rshift = @intCast(rshift),
                        .rshift_u8 = @intCast(rshift_u8)
                    };
                } else {
                    return MaskType{
                        .mask = @intCast(in_mask), 
                        .rshift = @intCast(rshift),
                        .lshift_u8 = @intCast(@abs(rshift_u8))
                    };
                }
            } else {
                if (rshift_u8 > 0) {
                    return MaskType{ 
                        .mask = @intCast(in_mask), 
                        .lshift = @intCast(@abs(rshift)),
                        .rshift_u8 = @intCast(rshift_u8),
                    };
                } else {
                    return MaskType{ 
                        .mask = @intCast(in_mask), 
                        .lshift = @intCast(@abs(rshift)),
                        .lshift_u8 = @intCast(@abs(rshift_u8)),
                    };
                }
            }
        } 

        inline fn extractComponent(self: *const MaskType, pixel: InPixelIntType) ImagePixelComponentType {
            return @intCast(((pixel & self.mask) >> self.rshift) << self.lshift);
        }

        inline fn extractComponentU8(self: *const MaskType, pixel: InPixelIntType) u8 {
            return @intCast(((pixel & self.mask) >> self.rshift_u8) << self.lshift_u8);
        }

    };
}

pub fn BitmapColorTransfer(comptime InPixelTag: types.PixelTag, comptime OutPixelTag: types.PixelTag) type {

    const InPixelIntType = InPixelTag.intType(); 
    const InPixelType = InPixelTag.toType();
    const OutPixelType = OutPixelTag.toType();

    const ComponentTypeSet = struct {
        RType: type = u1,
        GType: type = u1,
        BType: type = u1,
        AType: type = u1
    };

    const cmp_type_set = switch(OutPixelType) {
        types.RGBA32 =>    ComponentTypeSet{ .RType=u8,  .GType=u8,  .BType=u8,  .AType=u8 },
        types.RGB16 =>     ComponentTypeSet{ .RType=u5,  .GType=u6,  .BType=u5,  .AType=u1 },
        types.R8 =>        ComponentTypeSet{ .RType=u8,  .GType=u1,  .BType=u1,  .AType=u1 },
        types.R16 =>       ComponentTypeSet{ .RType=u16, .GType=u1,  .BType=u1,  .AType=u1 },
        types.R32F =>      ComponentTypeSet{ .RType=f32, .GType=u1,  .BType=u1,  .AType=u1 },
        types.RG64F =>     ComponentTypeSet{ .RType=f32, .GType=f32, .BType=u1,  .AType=u1 },
        types.RGBA128F =>  ComponentTypeSet{ .RType=f32, .GType=f32, .BType=f32, .AType=f32 },
        types.RGBA128 =>   ComponentTypeSet{ .RType=u32, .GType=u32, .BType=u32, .AType=u32 },
        else => ComponentTypeSet{},
    };

    return struct {

        const ReaderType = @This();

        r_mask: 
            if (transferInputSupported(InPixelType)) BitmapComponentMask(InPixelIntType, cmp_type_set.RType) 
            else void = undefined,
        g_mask: 
            if (transferInputSupported(InPixelType)) BitmapComponentMask(InPixelIntType, cmp_type_set.GType)
            else void = undefined,
        b_mask: 
            if (transferInputSupported(InPixelType)) BitmapComponentMask(InPixelIntType, cmp_type_set.BType)
            else void = undefined,
        a_mask: 
            if (transferInputSupported(InPixelType)) BitmapComponentMask(InPixelIntType, cmp_type_set.AType)
            else void = undefined,

        comptime IPType: type = OutPixelType,
        comptime FPType: type = InPixelType,

        pub fn standard(alpha_mask: u32) !ReaderType {
            const transfer_supported = comptime blk: { break :blk transferSupported(); };
            if (!transfer_supported) {
                return ImageError.TransferBetweenFormatsUnsupported;
            }
            return ReaderType{
                .r_mask = switch (InPixelIntType) {
                    u8 => try BitmapComponentMask(InPixelIntType, cmp_type_set.RType).new(0xe0),
                    u16 => switch(InPixelTag) {
                        .U16_RGB15 => try BitmapComponentMask(InPixelIntType, cmp_type_set.RType).new(0x7c00),
                        else => try BitmapComponentMask(InPixelIntType, cmp_type_set.RType).new(0xf800),
                    },
                    u24 => try BitmapComponentMask(InPixelIntType, cmp_type_set.RType).new(0xff0000),
                    u32 => try BitmapComponentMask(InPixelIntType, cmp_type_set.RType).new(0x00ff0000),
                    else => try BitmapComponentMask(InPixelIntType, u8).new(0),
                },
                .g_mask = switch (InPixelIntType) {
                    u8 => try BitmapComponentMask(InPixelIntType, cmp_type_set.GType).new(0x1c),
                    u16 => switch(InPixelTag) {
                        .U16_RGB15 => try BitmapComponentMask(InPixelIntType, cmp_type_set.GType).new(0x03e0),
                        else => try BitmapComponentMask(InPixelIntType, cmp_type_set.GType).new(0x07e0),
                    },
                    u24 => try BitmapComponentMask(InPixelIntType, cmp_type_set.GType).new(0x00ff00),
                    u32 => try BitmapComponentMask(InPixelIntType, cmp_type_set.GType).new(0x0000ff00),
                    else => try BitmapComponentMask(InPixelIntType, u8).new(0),
                },
                .b_mask = switch (InPixelIntType) {
                    u8 => try BitmapComponentMask(InPixelIntType, cmp_type_set.BType).new(0x03),
                    u16 => try BitmapComponentMask(InPixelIntType, cmp_type_set.BType).new(0x001f),
                    u24 => try BitmapComponentMask(InPixelIntType, cmp_type_set.BType).new(0x0000ff),
                    u32 => try BitmapComponentMask(InPixelIntType, cmp_type_set.BType).new(0x000000ff),
                    else => try BitmapComponentMask(InPixelIntType, u8).new(0),
                },
                .a_mask = switch (InPixelIntType) {
                    u8 => try BitmapComponentMask(InPixelIntType, cmp_type_set.AType).new(0),
                    u16 => try BitmapComponentMask(InPixelIntType, cmp_type_set.AType).new(0),
                    u24 => try BitmapComponentMask(InPixelIntType, cmp_type_set.AType).new(0),
                    u32 => try BitmapComponentMask(InPixelIntType, cmp_type_set.AType).new(alpha_mask),
                    else => try BitmapComponentMask(InPixelIntType, u8).new(0),
                },
            };
        }

        pub fn fromInfo(info: *const BitmapInfo) !ReaderType {
            const transfer_supported = comptime blk: { break :blk transferSupported(); };
            if (!transfer_supported) {
                return ImageError.TransferBetweenFormatsUnsupported;
            }
            return ReaderType{
                .r_mask = try BitmapComponentMask(InPixelIntType, cmp_type_set.RType).new(info.red_mask),
                .g_mask = try BitmapComponentMask(InPixelIntType, cmp_type_set.GType).new(info.green_mask),
                .b_mask = try BitmapComponentMask(InPixelIntType, cmp_type_set.BType).new(info.blue_mask),
                .a_mask = try BitmapComponentMask(InPixelIntType, cmp_type_set.AType).new(info.alpha_mask),
            };
        }

        pub fn transferRowFromBytes(self: *const ReaderType, in_row: [*]const u8, out_row: []OutPixelType) void {
            const transfer_supported = comptime blk: { break :blk transferSupported(); };
            if (!transfer_supported) {
                return;
            }
            const color_byte_sz: comptime_int = switch (InPixelIntType) {
                u8 => 1,
                u16 => 2,
                u24 => 3,
                u32 => 4,
                else => 0,
            };
            var row_byte: usize = 0;
            for (0..out_row.len) |i| {
                var in_pixel: InPixelIntType = undefined;
                if (InPixelIntType == u24) {
                    in_pixel = u24RGBFromBytes(&in_row[row_byte]);
                } else {
                    in_pixel = std.mem.readIntSliceLittle(InPixelIntType, in_row[row_byte..row_byte + color_byte_sz]);
                }
                self.transferColor(in_pixel, &out_row[i]);
                row_byte += color_byte_sz;
            }
        }

        pub fn transferColorTableImageRow(
            self: *const ReaderType,
            comptime IndexIntType: type,
            index_row: []const u8, 
            colors: []const InPixelType,
            image_row: []OutPixelType,
            row_byte_ct: u32, 
        ) !void {
            const base_mask: comptime_int = switch(IndexIntType) {
                u1 => 0x80,
                u4 => 0xf0,
                u8 => 0xff,
                else => unreachable,
            };
            const bit_width: comptime_int = @typeInfo(IndexIntType).Int.bits;
            const colors_per_byte: comptime_int = 8 / bit_width;

            var img_idx: usize = 0;
            for (0..row_byte_ct) |byte| {
                const idx_byte = index_row[byte];
                inline for (0..colors_per_byte) |j| {
                    if (img_idx + j >= image_row.len) {
                        return;
                    }
                    const mask_shift: comptime_int = j * bit_width;
                    const result_shift: comptime_int = ((colors_per_byte - 1) - j) * bit_width;
                    const mask = @as(u8, base_mask) >> mask_shift;
                    const col_idx: u8 = (idx_byte & mask) >> result_shift;
                    if (col_idx >= colors.len) {
                        return ImageError.InvalidColorTableIndex;
                    }
                    self.transferColor(colors[col_idx], &image_row[img_idx + j]);
                }
                img_idx += colors_per_byte;
            }
        }

        pub inline fn transferColor(self: *const ReaderType, in_pixel: InPixelType, out_pixel: *OutPixelType) void {
            switch (InPixelTag) { 
                .RGBA32, .RGB16 => {
                    out_pixel.setFromColor(in_pixel);
                },
                .R8, .R16, .U16_R, .U8_R => {
                    out_pixel.setFromGrey(in_pixel);
                },
                .U32_RGBA, .U16_RGBA => {
                    out_pixel.setFromRGBA(
                        self.r_mask.extractComponentU8(in_pixel),
                        self.g_mask.extractComponentU8(in_pixel),
                        self.b_mask.extractComponentU8(in_pixel),
                        self.a_mask.extractComponentU8(in_pixel),
                    );
                },
                .U32_RGB, .U24_RGB, .U16_RGB, .U16_RGB15 => {
                    out_pixel.setFromRGB(
                        self.r_mask.extractComponentU8(in_pixel),
                        self.g_mask.extractComponentU8(in_pixel),
                        self.b_mask.extractComponentU8(in_pixel),
                    );
                },
                else => {},
            }
        }

        inline fn RGBAverage(color: types.RGBA32, comptime OutputIntType: type) OutputIntType {
            const inv_grey_sum_max: comptime_float = 1.0 / @as(comptime_float, @floatFromInt(255 * 3));
            const max_cmp: comptime_float = @floatFromInt(std.math.maxInt(OutputIntType));
            const grey_sum: u32 = @as(u32, @intCast(color.r)) 
                + @as(u32, @intCast(color.g)) 
                + @as(u32, @intCast(color.b));
            const base_grey: f32 = @floatFromInt(grey_sum);
            const white_proportion: f32 = base_grey * inv_grey_sum_max;
            return @intFromFloat(white_proportion * max_cmp);
        }

        pub inline fn transferInputSupported(comptime PixelType: type) bool {
            return switch(PixelType) {
                types.RGBA32, types.RGB16, types.R8, types.R16, u32, u24, u16, u8 => true,
                else => false,
            };
        }

        pub inline fn transferOutputSupported(comptime PixelType: type) bool {
            return switch(PixelType) {
                types.RGBA32, types.RGB16, types.R8, types.R16 => true,
                else => false,
            };
        }

        pub inline fn transferSupported() bool {
            return transferInputSupported(InPixelType) and transferOutputSupported(OutPixelType);
        }

        pub fn inPixelIntType() type {
            return InPixelIntType;
        }

        pub fn inPixelType() type {
            return InPixelType;
        }

        pub fn outPixelType() type {
            return OutPixelType;
        }

    };
}

pub inline fn u24RGBFromBytes(bytes_in: *const u8) u24 {
    const bytes: [*]const u8 = @ptrCast(bytes_in);
    return (@as(u24, @intCast(bytes[2])) << @as(u5, 16)) 
        | (@as(u24, @intCast(bytes[1])) << @as(u4, 8)) 
        | (bytes[0]);
}

pub fn transferImage(in_image: *const Image, out_image: *Image) !void {
    switch(in_image.activePixelTag()) {
        inline .RGBA32, .RGB16, .R8, .R16 => |in_tag| {
            switch (out_image.activePixelTag()) {
                inline .RGBA32, .RGB16, .R8, .R16 => |out_tag| {
                    try transferImageKnownTags(in_tag, out_tag, in_image, out_image);
                },
                else => {}
            }
        },
        else => {},
    }
}

pub fn transferImageKnownTags(
    comptime in_tag: types.PixelTag, 
    comptime out_tag: types.PixelTag,
    in_image: *const Image, 
    out_image: *Image
) !void {
    const transfer = try BitmapColorTransfer(in_tag, out_tag).standard(0);
    const in_pixels = try in_image.getPixels(in_tag);
    const out_pixels = try out_image.getPixels(out_tag);
    if (in_pixels.len != out_pixels.len) {
        return ImageError.UnevenImageLengthsInTransfer;
    }
    if (in_tag == out_tag) {
        @memcpy(out_pixels, in_pixels);
    }
    else for (0..out_pixels.len) |i| {
        transfer.transferColor(in_pixels[i], &out_pixels[i]);
    }
}

pub fn TgaRLEReader(
    comptime IntType: type, 
    comptime color_table_img: bool, 
    comptime in_tag: types.PixelTag,
    comptime out_tag: types.PixelTag
) type {
    return struct {
        const RLEReaderType = @This();
        const ReadInfoType = TgaReadInfo(IntType);

        read_info: TgaReadInfo(IntType) = undefined,
        byte_pos: u32 = 0,
        action_ct: u32 = 0,
        cur_color: in_tag.toType() = undefined,
        transfer: BitmapColorTransfer(in_tag, out_tag) = undefined,

        pub fn new(info: *const TgaInfo, image: *const Image) !RLEReaderType {
            if (color_table_img and info.color_map.table == null) {
                return ImageError.ColorTableImageEmptyTable;
            }
            return RLEReaderType {
                .read_info = try TgaReadInfo(IntType).new(info, image),
                .transfer = try BitmapColorTransfer(in_tag, out_tag).standard(0xff000000),
            };
        }

        pub fn readAction(self: *RLEReaderType, image: *const Image, info: *const TgaInfo, buffer: []const u8) !RLEAction {
            const image_index = self.imageIndex(image);
            if (self.byte_pos >= buffer.len or image_index <= 0 or image_index >= image.len()) {
                return RLEAction.EndImage;
            }

            const action_byte = buffer[self.byte_pos];
            self.byte_pos += 1;
            self.action_ct = (action_byte & 0x7f) + 1;
            const action_bit = action_byte & 0x80;

            if (action_bit > 0) {
                if (color_table_img) {
                    try self.readNextColorTableColor(info, buffer);
                } else {
                    try self.readNextInlineColor(buffer);
                }
                return RLEAction.RepeatPixels;
            }
            else {
                return RLEAction.ReadPixels;
            }
        }

        pub fn repeatPixel(self: *RLEReaderType, image: *Image) !void {
            var image_pixels = try image.getPixels(out_tag);
            for (0..@intCast(self.action_ct)) |i| {
                _ = i;
                const image_idx: usize = try self.imageIndexChecked(image);
                self.transfer.transferColor(self.cur_color, &image_pixels[image_idx]);
                self.pixelStep(image);
            }
        }

        pub fn readPixels(self: *RLEReaderType, buffer: []const u8, info: *const TgaInfo, image: *Image) !void {
            var image_pixels = try image.getPixels(out_tag);
            for (0..@intCast(self.action_ct)) |i| {
                _ = i;
                const image_idx: usize = try self.imageIndexChecked(image);
                if (color_table_img) {
                    try self.readNextColorTableColor(info, buffer);
                } else {
                    try self.readNextInlineColor(buffer);
                }
                self.transfer.transferColor(self.cur_color, &image_pixels[image_idx]);
                self.pixelStep(image);
            }
        }

        inline fn imageIndex(self: *const RLEReaderType, image: *const Image) i32 {
            return self.read_info.coords.y * @as(i32, @intCast(image.width)) + self.read_info.coords.x;
        }

        fn imageIndexChecked(self: *const RLEReaderType, image: *const Image) !usize {
            const image_idx_signed: i32 = self.imageIndex(image);
            if (image_idx_signed < 0) {
                return ImageError.UnexpectedEndOfImageBuffer;
            }
            const image_idx: usize = @intCast(image_idx_signed);
            if (image_idx >= self.read_info.pixel_ct) {
                return ImageError.UnexpectedEndOfImageBuffer;
            }
            return image_idx;
        }

        inline fn pixelStep(self: *RLEReaderType, image: *const Image) void {
            self.read_info.coords.x += 1;
            if (self.read_info.coords.x >= image.width) {
                self.read_info.coords.x = 0;
                self.read_info.coords.y += self.read_info.write_dir;
            }
        }

        fn readNextInlineColor(self: *RLEReaderType, buffer: []const u8) !void {
            if (@TypeOf(self.cur_color) == types.RGBA32) {
                return;
            }
            const new_byte_pos = self.byte_pos + ReadInfoType.pixelSz();
            if (new_byte_pos > buffer.len) {
                return ImageError.UnexpectedEndOfImageBuffer;
            }
            if (in_tag.toType() == u24) {
                self.cur_color = (@as(u24, @intCast(buffer[self.byte_pos+2])) << @as(u5, 16)) 
                    | (@as(u24, @intCast(buffer[self.byte_pos+1])) << @as(u4, 8)) 
                    | (buffer[self.byte_pos]);
            } else {
                self.cur_color = std.mem.readIntSliceLittle(
                    in_tag.toType(), buffer[self.byte_pos..self.byte_pos+in_tag.size()]
                );
            }
            self.byte_pos = new_byte_pos;
        }

        fn readNextColorTableColor(self: *RLEReaderType, info: *const TgaInfo, buffer: []const u8) !void {
            if (@TypeOf(self.cur_color) != types.RGBA32) {
                return;
            }
            const new_byte_pos = self.byte_pos + ReadInfoType.pixelSz();
            if (new_byte_pos > buffer.len) {
                return ImageError.UnexpectedEndOfImageBuffer;
            }
            const color_table = info.color_map.table.?;
            const pixel = std.mem.readIntSliceLittle(IntType, buffer[self.byte_pos..new_byte_pos]);
            if (pixel >= color_table.len) {
                return ImageError.InvalidColorTableIndex;
            }
            self.cur_color = info.color_map.table.?[pixel];
            self.byte_pos = new_byte_pos;
        }

    };
}

pub fn BmpRLEReader(
    comptime IndexIntType: type, comptime InPixelTag: types.PixelTag, comptime OutPixelTag: types.PixelTag
) type {
    return struct {
        const RLEReaderType = @This();

        img_col: u32 = 0,
        img_row: u32 = 0,
        img_width: u32 = 0,
        img_height: u32 = 0,
        byte_pos: u32 = 0,
        img_write_end: bool = false,
        action_bytes: [2]u8 = undefined,
        transfer: BitmapColorTransfer(InPixelTag, OutPixelTag),

        const read_min_multiple: u8 = switch (IndexIntType) {
            u4 => 4,
            u8 => 2,
            else => unreachable,
        };
        const read_min_shift: u8 = switch (IndexIntType) {
            u4 => 2,
            u8 => 1,
            else => unreachable,
        };
        const byte_shift: u8 = switch (IndexIntType) {
            u4 => 1,
            u8 => 0,
            else => unreachable,
        };

        pub fn new(image_width: u32, image_height: u32) !RLEReaderType {
            return RLEReaderType{
                .img_row = image_height - 1,
                .img_width = image_width,
                .img_height = image_height,
                .byte_pos = 0,
                .transfer = try BitmapColorTransfer(InPixelTag, OutPixelTag).standard(0),
            };
        }

        pub fn readAction(self: *RLEReaderType, buffer: []const u8) !RLEAction {
            if (self.byte_pos + 1 >= buffer.len) {
                return ImageError.UnexpectedEndOfImageBuffer;
            }
            self.action_bytes[0] = buffer[self.byte_pos];
            self.action_bytes[1] = buffer[self.byte_pos + 1];
            self.byte_pos += 2;

            if (self.img_write_end) { // ended by writing to the final row
                return RLEAction.EndImage;
            } else if (self.action_bytes[0] > 0) {
                return RLEAction.RepeatPixels;
            } else if (self.action_bytes[1] > 2) {
                return RLEAction.ReadPixels;
            } else { // 0 = EndRow, 1 = EndImage, 2 = Move
                return @enumFromInt(self.action_bytes[1]);
            }
        }

        pub fn repeatPixel(self: *RLEReaderType, color_table: *const BitmapColorTable, image: *Image) !void {
            const repeat_ct = self.action_bytes[0];
            const col_end = self.img_col + repeat_ct;
            const img_idx_end = self.img_row * self.img_width + col_end;

            if (img_idx_end > image.len()) {
                return ImageError.BmpInvalidRLEData;
            }
            var img_idx = self.imageIndex();
            var image_pixels = try image.getPixels(OutPixelTag);
            const table_colors = try color_table.palette.getPixels(InPixelTag);

            switch (IndexIntType) {
                u4 => {
                    const color_indices: [2]u8 = .{ (self.action_bytes[1] & 0xf0) >> 4, self.action_bytes[1] & 0x0f };
                    if (color_indices[0] >= table_colors.len or color_indices[1] >= table_colors.len) {
                        return ImageError.InvalidColorTableIndex;
                    }

                    var color_idx: u8 = 0;
                    const colors: [2]InPixelTag.toType() = .{ 
                        table_colors[color_indices[0]], table_colors[color_indices[1]] 
                    };
                    while (img_idx < img_idx_end) : (img_idx += 1) {
                        self.transfer.transferColor(colors[color_idx], &image_pixels[img_idx]);
                        color_idx = 1 - color_idx;
                    }
                },
                u8 => {
                    const color_idx = self.action_bytes[1];
                    if (color_idx >= table_colors.len) {
                        return ImageError.InvalidColorTableIndex;
                    }

                    const color = table_colors[color_idx];
                    while (img_idx < img_idx_end) : (img_idx += 1) {
                        self.transfer.transferColor(color, &image_pixels[img_idx]);
                    }
                },
                else => unreachable,
            }
            self.img_col = col_end;
        }

        pub fn readPixels(
            self: *RLEReaderType, 
            buffer: []const u8, 
            color_table: *const BitmapColorTable, 
            image: *Image
        ) !void {
            const read_ct = self.action_bytes[1];
            const col_end = self.img_col + read_ct;
            const img_idx_end = self.img_row * self.img_width + col_end;

            if (img_idx_end > image.len()) {
                return ImageError.BmpInvalidRLEData;
            }

            // read_ct = 3
            const word_read_ct = read_ct >> read_min_shift; // 3 / 4 = 0
            const word_leveled_read_ct = word_read_ct << read_min_shift; // 0 * 4 = 0
            const word_truncated: u8 = @intFromBool(word_leveled_read_ct != read_ct); // true
            const word_aligned_read_ct: u32 = @as(u32, @intCast(word_leveled_read_ct)) + read_min_multiple * word_truncated; // 0 + 4
            const byte_read_end = self.byte_pos + (word_aligned_read_ct >> byte_shift); //  add 4

            if (byte_read_end >= buffer.len) {
                return ImageError.UnexpectedEndOfImageBuffer;
            }

            var image_pixels = try image.getPixels(OutPixelTag);
            const table_colors = try color_table.palette.getPixels(InPixelTag);
            var img_idx = self.imageIndex();
            var byte_idx: usize = self.byte_pos;

            switch (IndexIntType) {
                u4 => {
                    var high_low: u1 = 0;
                    const masks: [2]u8 = .{ 0xf0, 0x0f };
                    const shifts: [2]u3 = .{ 4, 0 };
                    while (img_idx < img_idx_end) : (img_idx += 1) {
                        const color_idx = (buffer[byte_idx] & masks[high_low]) >> shifts[high_low];
                        if (color_idx >= table_colors.len) {
                            return ImageError.InvalidColorTableIndex;
                        }
                        self.transfer.transferColor(table_colors[color_idx], &image_pixels[img_idx]);
                        byte_idx += high_low;
                        high_low = 1 - high_low;
                    }
                },
                u8 => {
                    while (img_idx < img_idx_end) : (img_idx += 1) {
                        const color_idx: IndexIntType = buffer[byte_idx];
                        if (color_idx >= table_colors.len) {
                            return ImageError.InvalidColorTableIndex;
                        }
                        self.transfer.transferColor(table_colors[color_idx], &image_pixels[img_idx]);
                        byte_idx += 1;
                    }
                },
                else => unreachable,
            }
            self.byte_pos = byte_read_end;
            self.img_col = col_end;
        }

        pub inline fn imageIndex(self: *const RLEReaderType) u32 {
            return self.img_row * self.img_width + self.img_col;
        }

        pub fn changeCoordinates(self: *RLEReaderType, buffer: []const u8) !void {
            if (self.byte_pos + 1 >= buffer.len) {
                return ImageError.UnexpectedEndOfImageBuffer;
            }
            self.img_col += buffer[self.byte_pos];
            const new_row = @as(i32, @intCast(self.img_row)) - @as(i32, @intCast(buffer[self.byte_pos + 1]));

            if (new_row < 0) {
                self.img_write_end = true;
            } else {
                self.img_row = @intCast(new_row);
            }
            self.byte_pos += 2;
        }

        pub fn incrementRow(self: *RLEReaderType) void {
            self.img_col = 0;
            const new_row: i32 = @as(i32, @intCast(self.img_row)) - 1;

            if (new_row < 0) {
                self.img_write_end = true;
            } else {
                self.img_row = @intCast(new_row);
            }
        }
    };
}

fn tgaImageOrigin(image_spec: *const TgaImageSpec) types.I32x2 {
    const bit4: bool = (image_spec.descriptor & 0x10) != 0;
    const bit5: bool = (image_spec.descriptor & 0x20) != 0;
    // imagine the image buffer is invariably stored in in a 2d array of rows stacked upward, on an xy plane with the
    // first buffer pixel at (0, 0). This might take a little brain jiu-jitsu since we normally thing of arrays as 
    // top-down. If the origin (top left of output image) is also at (0, 0), we should read left-to-right, bottom-to-top.
    // In practice, we read the buffer from beginning to end and write depending on the origin.
    if (bit4) {
        if (bit5) {
            // top right
            return .{.x=image_spec.image_width - 1, .y=image_spec.image_height - 1};
        } else {
            // bottom right
            return .{.x=image_spec.image_width - 1, .y=0};
        }
    } else {
        if (bit5) {
            // top left
            return .{.x=0, .y=image_spec.image_height - 1};
        } else {
            // bottom left
            return .{.x=0, .y=0};
        }
    }
}

pub fn TgaReadInfo (comptime PixelType: type) type {

    const pixel_sz: comptime_int = switch(PixelType) { // sizeOf(u24) gives 4
        u8 => 1,
        u15, u16 => 2,
        u24 => 3,
        u32 => 4,
        else => unreachable,
    };

    return struct {
        const TRIType = @This();

        image_sz: i32 = undefined,
        pixel_ct: u32 = undefined,
        read_start: i32 = undefined,
        read_row_step: i32 = undefined,
        coords: types.I32x2 = undefined,
        write_start: i32 = undefined,
        write_row_step: i32 = undefined,
        write_dir: i32 = 1,

        pub fn new(info: *const TgaInfo, image: *const Image) !TRIType {
            var read_info = TRIType{};
            
            const image_spec = info.header.image_spec;
            const width_sz = image.width * pixel_sz;
            read_info.image_sz = @intCast(width_sz * image.height);
            read_info.pixel_ct = image.width * image.height;
            read_info.read_start = 0;
            read_info.read_row_step = @intCast(width_sz);

            read_info.coords = tgaImageOrigin(&image_spec);

            if (read_info.coords.x != 0) {
                return ImageError.TgaUnsupportedImageOrigin;
            } 

            if (read_info.coords.y == 0) {
                // image rows stored bottom-to-top
                read_info.write_start = @intCast(read_info.pixel_ct - image.width);
                read_info.write_row_step = -@as(i32, @intCast(image.width));
                // if coordinates are used, they will be used for writing in the opposite direction
                read_info.coords.y = @as(i32, @intCast(image.height)) - 1;
                read_info.write_dir = -1;
            }
            else {
                // image rows stored top-to-bottom
                read_info.write_start = 0;
                read_info.write_row_step = @intCast(image.width);
                // if coordinates are used, they will be used for writing in the opposite direction
                read_info.coords.y = 0;
            }

            return read_info;
        }

        pub inline fn pixelSz() u32 {
            return @intCast(pixel_sz);
        }
    };
}
