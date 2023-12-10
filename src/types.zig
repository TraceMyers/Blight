const std = @import("std");
const imagef = @import("image.zig");
const readerf = @import("reader.zig");
const tga = @import("tga.zig");
const bmp = @import("bmp.zig");

// --- Image pixel types ---

pub const RGBA32 = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,

    pub inline fn getR(self: *const RGBA32) u8 {
        return self.r;
    }

    pub inline fn getG(self: *const RGBA32) u8 {
        return self.g;
    }

    pub inline fn getB(self: *const RGBA32) u8 {
        return self.b;
    }

    pub inline fn getA(self: *const RGBA32) u8 {
        return self.a;
    }

    pub inline fn setR(self: *RGBA32, r: u8) void {
        self.r = r;
    }

    pub inline fn setG(self: *RGBA32, g: u8) void {
        self.g = g;
    }

    pub inline fn setB(self: *RGBA32, b: u8) void {
        self.b = b;
    }

    pub inline fn setA(self: *RGBA32, a: u8) void {
        self.a = a;
    }

    pub inline fn setFromRGB(self: *RGBA32, r: u8, g: u8, b: u8) void {
        self.r = r;
        self.g = g;
        self.b = b;
        self.a = 255;
    }

    pub inline fn setFromRGBA(self: *RGBA32, r: u8, g: u8, b: u8, a: u8) void {
        self.r = r;
        self.g = g;
        self.b = b;
        self.a = a;
    }

    pub inline fn setFromGrey(self: *RGBA32, r: anytype) void {
        switch(@TypeOf(r)) {
            u8 => self.setFromRGB(r, r, r),
            u16 => {
                const grey: u8 = @intCast(r >> 8);
                self.setFromRGB(grey, grey, grey);
            },
            R8 => self.setFromRGB(r.r, r.r, r.r),
            R16 => {
                const grey: u8 = @intCast(r.r >> 8);
                self.setFromRGB(grey, grey, grey);
            },
            else => unreachable,
        }
    }

    // always clears alpha unless setting from RGBA32
    pub inline fn setFromColor(self: *RGBA32, c: anytype) void {
        switch(@TypeOf(c)) {
            u15 => self.setFromRGB((c & 0x7c00) >> 7, (c & 0x03e0) >> 2, (c & 0x001f) << 3),
            u16 => self.setFromRGB((c & 0xf800) >> 8, (c & 0x07e0) >> 2, (c & 0x001f) << 3),
            u24, u32 => self.setFromRGB((c & 0xff0000) >> 16, (c & 0x00ff00) >> 8, (c & 0x0000ff)),
            RGB16 => self.setFromRGB((c.c & 0xf800) >> 8, (c.c & 0x07e0) >> 2, (c.c & 0x001f) << 3),
            RGBA32 => self.* = c,
            BGR32, BGR24 => self.setFromRGB(c.r, c.g, c.b),
            else => unreachable,
        }
    }
};

// I was unable to get a packed struct with r:u5, g:u6, b:u5 components to work
// so, 'c' stands for components!
pub const RGB16 = extern struct {
    // r: 5, g: 6, b: 5
    c: u16,

    pub inline fn getR(self: *const RGB16) u8 {
        return @intCast((self.c & 0xf800) >> 8);
    }

    pub inline fn getG(self: *const RGB16) u8 {
        return @intCast((self.c & 0x07e0) >> 3);
    }

    pub inline fn getB(self: *const RGB16) u8 {
        return @intCast((self.c & 0x001f) << 3);
    }

    pub inline fn setR(self: *RGB16, r: u8) void {
        self.c = (self.c & ~0xf800) | ((r & 0xf8) << 8);
    } 

    pub inline fn setG(self: *RGB16, g: u8) void {
        self.c = (self.c & ~0x07e0) | ((g & 0xfc) << 3);
    }

    pub inline fn setB(self: *RGB16, b: u8) void {
        self.c = (self.c & ~0x001f) | ((b & 0xf8) >> 3);
    }

    pub inline fn setFromRGB(self: *RGB16, r: u8, g: u8, b: u8) void {
        self.c = ((@as(u16, @intCast(r)) & 0xf8) << 8) 
            | ((@as(u16, @intCast(g)) & 0xfc) << 3) 
            | ((@as(u16, @intCast(b)) & 0xf8) >> 3);
    }

    pub inline fn setFromRGBA(self: *RGB16, r: u8, g: u8, b: u8, a: u8) void {
        _ = a;
        self.setFromRGB(r, g, b);
    }

    pub inline fn setFromGrey(self: *RGB16, r: anytype) void {
        switch(@TypeOf(r)) {
            u8 => self.setFromRGB(r, r, r),
            u16 => self.c = (r & 0xf800) | ((r & 0xfc00) >> 5) | ((r & 0xf800) >> 11),
            R8 => self.setFromRGB(r.r, r.r, r.r),
            R16 => self.r = (r.r & 0xf800) | ((r.r & 0xfc00) >> 5) | ((r.r & 0xf800) >> 11),
            else => unreachable,
        }
    }

    pub inline fn setFromColor(self: *RGB16, c: anytype) void {
        switch(@TypeOf(c)) {
            u15 => self.c = (@as(u16, @intCast(c & 0x7fc0)) << 1) | (c & 0x003f),
            u16 => self.c = c,
            u24, u32 => self.c = (@as(u16, @intCast((c & 0xf80000) >> 8)))
                | (@as(u16, @intCast((c & 0x00fc00) >> 5)))
                | (@as(u16, @intCast((c & 0x0000f8) >> 3))),
            RGB16 => self.c = c.c,
            RGBA32, BGR32, BGR24 => self.setFromRGB(c.r, c.g, c.b),
            else => unreachable,
        }
    }
};

pub const RGB15 = extern struct {
    // r: 5, g: 5, b: 5
    c: u16, 

    pub inline fn getR(self: *const RGB15) u8 {
        return @intCast((self.c & 0x7c00) >> 8);
    }

    pub inline fn getG(self: *const RGB15) u8 {
        return @intCast((self.c & 0x03e0) >> 3);
    }

    pub inline fn getB(self: *const RGB15) u8 {
        return @intCast((self.c & 0x001f) << 3);
    }

    pub inline fn setR(self: *RGB15, r: u8) void {
        // 0xfc00 here to clear the most significant 6 bits even though we're only setting the 5 least significant of 
        // the 6 most significant
        self.c = (self.c & ~0xfc00) | ((r & 0xf8) << 7);
    } 

    pub inline fn setG(self: *RGB15, g: u8) void {
        self.c = (self.c & ~0x03e0) | ((g & 0xf8) << 3);
    }

    pub inline fn setB(self: *RGB15, b: u8) void {
        self.c = (self.c & ~0x001f) | ((b & 0xf8) >> 3);
    }

    pub inline fn setFromRGB(self: *RGB15, r: u8, g: u8, b: u8) void {
        self.c = ((@as(u16, @intCast(r)) & 0xf8) << 7) 
            | ((@as(u16, @intCast(g)) & 0xf8) << 3) 
            | ((@as(u16, @intCast(b)) & 0xf8) >> 3);
    }

    pub inline fn setFromRGBA(self: *RGB15, r: u8, g: u8, b: u8, a: u8) void {
        _ = a;
        self.setFromRGB(r, g, b);
    }

    pub inline fn setFromGrey(self: *RGB15, r: anytype) void {
        switch(@TypeOf(r)) {
            u8 => self.setFromRGB(r, r, r),
            u16 => self.c = ((r & 0xf800) >> 1) | ((r & 0xfc00) >> 6) | ((r & 0xf800) >> 11),
            R8 => self.setFromRGB(r.r, r.r, r.r),
            R16 => self.c = ((r.r & 0xf800) >> 1) | ((r.r & 0xfc00) >> 6) | ((r.r & 0xf800) >> 11),
            else => unreachable,
        }
    }

    pub inline fn setFromColor(self: *RGB15, c: anytype) void {
        switch(@TypeOf(c)) {
            u15 => self.c = @as(u16, c),
            u16 => self.c = ((c & 0xf8c0) >> 1) | (c & 0x003f),
            u24, u32 => self.c = (@as(u16, @intCast((c & 0xf80000) >> 9)))
                | (@as(u16, @intCast((c & 0x00f800) >> 6)))
                | (@as(u16, @intCast((c & 0x0000f8) >> 3))),
            RGB16 => self.c = ((c.c & 0xf8c0) >> 1) | (c.c & 0x003f),
            RGBA32, BGR32, BGR24 => self.setFromRGB(c.r, c.g, c.b),
            else => unreachable,
        }
    }
};

pub const R8 = extern struct {
    r: u8 = 0,

    pub inline fn getR(self: *const R8) u8 {
        return self.r;
    }

    pub inline fn setR(self: *const R8, r: u8) void {
        self.r = r;
    }

    pub inline fn setFromRGB(self: *R8, r: u8, g: u8, b: u8) void {
        self.r = @as(u8, @intCast((@as(u16, @intCast(r)) + @as(u16, @intCast(g)) + @as(u16, @intCast(b))) >> 8));
    }

    pub inline fn setFromRGBA(self: *R8, r: u8, g: u8, b: u8, a: u8) void {
        _ = a;
        self.setFromRGB(r, g, b);
    }

    pub inline fn setFromGrey(self: *R8, r: anytype) void {
        switch(@TypeOf(r)) {
            u8 => self.r = r,
            u16 => self.r = @as(u8, @intCast(r >> 8)),
            R8 => self.* = r,
            R16 => self.r = @as(u8, @intCast(r.r >> 8)),
            else => unreachable,
        }
    }

    pub inline fn setFromColor(self: *R8, c: anytype) void {
        switch(@TypeOf(c)) {
            u15 => self.r = 
                (   @as(u8, @intCast((c & 0x7c00) >> 10))
                    + @as(u8, @intCast((c & 0x03e0) >> 5))
                    + @as(u8, @intCast(c & 0x001f))
                ) * 3 - 8,
            u16 => self.r = 
                (   @as(u8, @intCast((c & 0xf800) >> 11))
                    + @as(u8, @intCast((c & 0x07c0) >> 6))
                    + @as(u8, @intCast(c & 0x001f))
                ) * 3 - 8,
            u24, u32 => self.r = @as(u8, @intCast(
                (((c & 0xff0000) >> 16) + ((c & 0x00ff00) >> 8) + ((c & 0x0000ff))) >> 8
            )),
            RGB16 => self.r =
                (   @as(u8, @intCast((c.c & 0xf800) >> 11))
                    + @as(u8, @intCast((c.c & 0x07c0) >> 6))
                    + @as(u8, @intCast(c.c & 0x001f))
                ) * 3 - 8,
            RGBA32, BGR32, BGR24 => self.setFromRGB(c.r, c.g, c.b),
            else => unreachable,
        }
    }
};

pub const R16 = extern struct {
    r: u16 = 0,

    pub inline fn getR(self: *const R16) u16 {
        return self.r;
    }

    pub inline fn getRu8(self: *const R16) u8 {
        return @intCast(self.r >> 8);
    }

    pub inline fn setR(self: *const R16, r: u8) void {
        self.r = r;
    }

    pub inline fn setFromRGB(self: *R16, r: u8, g: u8, b: u8) void {
        self.r = (@as(u16, @intCast(r)) + @as(u16, @intCast(g)) + @as(u16, @intCast(b))) * 85;
    }

    pub inline fn setFromRGBA(self: *R16, r: u8, g: u8, b: u8, a: u8) void {
        _ = a;
        self.setFromRGB(r, g, b);
    }

    pub inline fn setFromGrey(self: *R16, r: anytype) void {
        switch(@TypeOf(r)) {
            u8 => self.r = @as(u16, @intCast(r)) << 8,
            u16 => self.r = r,
            R8 => self.r = @as(u16, @intCast(r.r)) << 8,
            R16 => self.* = r,
            else => unreachable,
        }
    }

    pub inline fn setFromColor(self: *R16, c: anytype) void {
        switch(@TypeOf(c)) {
            u15 => self.r = (((c & 0x7c00) >> 10) + ((c & 0x03e0) >> 5) + ((c & 0x001f))) * 705 + 8,
            u16 => self.r = (((c & 0xf800) >> 11) + ((c & 0x07c) >> 6) + ((c & 0x001f))) * 705 + 8,
            u24, u32 => self.setFromRGB((c & 0xff0000) >> 16, (c & 0x00ff00) >> 8, c & 0x0000ff),
            RGB16 => self.r = (((c.c & 0xf800) >> 11) + ((c.c & 0x07c) >> 6) + ((c.c & 0x001f))) * 705 + 8,
            RGBA32, BGR32, BGR24 => self.setFromRGB(c.r, c.g, c.b),
            else => unreachable,
        }
    }

};

pub const R32 = extern struct {
    r: u32 = 0,
};

pub const RGBA128F = extern struct {
    r: f32 = 0.0,
    g: f32 = 0.0,
    b: f32 = 0.0,
    a: f32 = 0.0,
};

pub const RGBA128 = extern struct {
    r: u32 = 0,
    g: u32 = 0,
    b: u32 = 0,
    a: u32 = 0,
};

pub const R32F = extern struct {
    r: f32 = 0.0,
};

pub const RG64F = extern struct {
    r: f32 = 0.0,
    g: f32 = 0.0,
};

// --- extra file load-only pixel types ---

pub const RGB24 = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
};

pub const RGB32 = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    reserved: u8 = 0,
};

pub const BGR24 = extern struct {
    b: u8 = 0,
    g: u8 = 0,
    r: u8 = 0,

    pub inline fn setFromRGB(self: *RGBA32, r: u8, g: u8, b: u8) void {
        self.b = b;
        self.g = g;
        self.r = r;
    }

    pub inline fn setFromRGBA(self: *RGBA32, r: u8, g: u8, b: u8, a: u8) void {
        _ = a;
        self.b = b;
        self.g = g;
        self.r = r;
    }

    pub inline fn setFromGrey(self: *RGBA32, r: anytype) void {
        switch(@TypeOf(r)) {
            u8 => self.setFromRGB(r, r, r),
            u16 => {
                const grey: u8 = @intCast(r >> 8);
                self.setFromRGB(grey, grey, grey);
            },
            R8 => self.setFromRGB(r.r, r.r, r.r),
            R16 => {
                const grey: u8 = @intCast(r.r >> 8);
                self.setFromRGB(grey, grey, grey);
            },
            else => unreachable,
        }
    }

    pub inline fn setFromColor(self: *RGBA32, c: anytype) void {
        switch(@TypeOf(c)) {
            u15 => self.setFromRGB((c & 0x7c00) >> 7, (c & 0x03e0) >> 2, (c & 0x001f) << 3),
            u16 => self.setFromRGB((c & 0xf800) >> 8, (c & 0x07e0) >> 2, (c & 0x001f) << 3),
            u24, u32 => self.setFromRGB((c & 0xff0000) >> 16, (c & 0x00ff00) >> 8, (c & 0x0000ff)),
            RGB16 => self.setFromRGB((c.c & 0xf800) >> 8, (c.c & 0x07e0) >> 2, (c.c & 0x001f) << 3),
            BGR24 => self.* = c,
            BGR32, RGBA32 => self.setFromRGB(c.r, c.g, c.b),
            else => unreachable,
        }
    }
};

pub const BGR32 = extern struct {
    b: u8 = 0,
    g: u8 = 0,
    r: u8 = 0,
    reserved: u8 = 0,

    pub inline fn setFromRGB(self: *BGR32, r: u8, g: u8, b: u8) void {
        self.b = b;
        self.g = g;
        self.r = r;
    }

    pub inline fn setFromRGBA(self: *BGR32, r: u8, g: u8, b: u8, a: u8) void {
        _ = a;
        self.b = b;
        self.g = g;
        self.r = r;
    }

    pub inline fn setFromGrey(self: *BGR32, r: anytype) void {
        switch(@TypeOf(r)) {
            u8 => self.setFromRGB(r, r, r),
            u16 => {
                const grey: u8 = @intCast(r >> 8);
                self.setFromRGB(grey, grey, grey);
            },
            R8 => self.setFromRGB(r.r, r.r, r.r),
            R16 => {
                const grey: u8 = @intCast(r.r >> 8);
                self.setFromRGB(grey, grey, grey);
            },
            else => unreachable,
        }
    }

    pub inline fn setFromColor(self: *BGR32, c: anytype) void {
        switch(@TypeOf(c)) {
            u15 => self.setFromRGB(
                @as(u8, @intCast((c & 0x7c00) >> 7)), 
                @as(u8, @intCast((c & 0x03e0) >> 2)), 
                @as(u8, @intCast((c & 0x001f) << 3))),
            u16 => self.setFromRGB(
                @as(u8, @intCast((c & 0xf800) >> 8)), 
                @as(u8, @intCast((c & 0x07e0) >> 2)), 
                @as(u8, @intCast((c & 0x001f) << 3))),
            u24, u32 => self.setFromRGB(
                @as(u8, @intCast((c & 0xff0000) >> 16)), 
                @as(u8, @intCast((c & 0x00ff00) >> 8)), 
                @as(u8, @intCast((c & 0x0000ff)))),
            RGB16 => self.setFromRGB(
                @as(u8, @intCast((c.c & 0xf800) >> 8)), 
                @as(u8, @intCast((c.c & 0x07e0) >> 2)), 
                @as(u8, @intCast(((c.c & 0x001f) << 3)))),
            BGR32 => self.* = c,
            RGBA32, BGR24 => self.setFromRGB(c.r, c.g, c.b),
            else => unreachable,
        }
    }
};

pub const ARGB64 = extern struct {
    a: u16,
    r: u16,
    g: u16,
    b: u16,
};

pub const RGBA64 = extern struct {
    r: u16 = 0,
    g: u16 = 0,
    b: u16 = 0,
    a: u16 = 0,
};

// --------------------------

pub const PixelTag = enum { 
    // valid image pixel formats
    RGBA32, RGB16, R8, R16, R32F, RG64F, RGBA128F, RGBA128, BGR32, BGR24,
    // valid internal/file pixel formats
    U32_RGBA, U32_RGB, U24_RGB, U16_RGBA, U16_RGB, U16_RGB15, U16_R, U8_R,
    
    pub fn size(self: PixelTag) usize {
        return switch(self) {
            .RGBA32 => 4,
            .RGB16 => 2,
            .R8 => 1, 
            .R16 => 2, 
            .R32F => 4,
            .RG64F => 8,
            .RGBA128F => 16,
            .RGBA128 => 16,
            .BGR32 => 4,
            .BGR24 => 3,
            .U32_RGBA => 4,
            .U32_RGB => 4,
            .U24_RGB => 3,
            .U16_RGBA => 2,
            .U16_RGB => 2,
            .U16_RGB15 => 2,
            .U16_R => 2,
            .U8_R => 1,
        };
    }

    pub fn isColor(self: PixelTag) bool {
        return switch(self) {
            .RGBA32, .RGB16, .RGBA128F, .RGBA128, .U32_RGBA, .U32_RGB, .U24_RGB, .U16_RGBA, .U16_RGB, .U16_RGB15,
            .BGR32, .BGR24 => true,
            else => false,
        };
    }

    pub fn hasAlpha(self: PixelTag) bool {
        return switch(self) {
            .RGBA32, .RGBA128F, .RGBA128, .U32_RGBA, .U16_RGBA => true,
            else => false,
        };
    }

    pub fn canBeLoadedFromCommonFormat(self: PixelTag) bool {
        return switch(self) {
            .RGBA32, .RGB16, .R8, .R16 => true,
            else => false,
        };
    }

    pub fn canBeImage(self: PixelTag) bool {
        return switch(self) {
            .RGBA32, .RGB16, .R8, .R16, .R32F, .RG64F, .RGBA128F, .RGBA128, .BGR32, .BGR24, => true,
            else => false,
        };
    }

    pub fn intType(comptime self: PixelTag) type {
        return switch(self) {
            .RGBA32 => u32,
            .RGB16 => u16,
            .R8 => u8, 
            .R16 => u16,
            .R32F => f32,
            .RG64F => f64,
            .RGBA128F => f128,
            .RGBA128 => u128,
            .BGR32 => u32,
            .BGR24 => u24,
            .U32_RGBA => u32,
            .U32_RGB => u32,
            .U24_RGB => u24,
            .U16_RGBA => u16,
            .U16_RGB => u16,
            .U16_RGB15 => u16,
            .U16_R => u16,
            .U8_R => u8,
        };
    }

    pub fn toType(comptime self: PixelTag) type {
        return switch(self) {
            .RGBA32 => RGBA32,
            .RGB16 => RGB16,
            .R8 => R8, 
            .R16 => R16,
            .R32F => R32F,
            .RG64F => RG64F,
            .RGBA128F => RGBA128F,
            .RGBA128 => RGBA128,
            .BGR32 => BGR32,
            .BGR24 => BGR24,
            .U32_RGBA => u32,
            .U32_RGB => u32,
            .U24_RGB => u24,
            .U16_RGBA => u16,
            .U16_RGB => u16,
            .U16_RGB15 => u16,
            .U16_R => u16,
            .U8_R => u8,
        };
    }
};

pub const PixelTagPair = struct {
    in_tag: PixelTag = PixelTag.RGBA32,
    out_tag: PixelTag = PixelTag.RGBA32,
};

pub const F32x2 = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
};

pub const I32x2 = struct {
    x: i32 = 0,
    y: i32 = 0
};

pub const ImageLoadBuffer = struct {
    allocation: ?[]u8 = null,
    alignment: u29 = 0
};

pub const PixelSlice = union(PixelTag) {
    RGBA32: []RGBA32,
    RGB16: []RGB16,
    R8: []R8,
    R16: []R16,
    R32F: []R32F,
    RG64F: []RG64F,
    RGBA128F: []RGBA128F,
    RGBA128: []RGBA128,
    BGR32: []BGR32,
    BGR24: []BGR24,
    U32_RGBA: []u32,
    U32_RGB: []u32,
    U24_RGB: []u24,
    U16_RGBA: []u16,
    U16_RGB: []u16,
    U16_RGB15: []u16,
    U16_R: []u16,
    U8_R: []u8,
};

pub const PixelContainer = struct {
    bytes: ?[]u8 = null,
    pixels: PixelSlice = PixelSlice{ .RGBA32 = undefined },
    allocator: ?std.mem.Allocator = null,

    pub fn alloc(self: *PixelContainer, in_allocator: std.mem.Allocator, in_tag: PixelTag, count: usize) !void {
        if (!in_tag.canBeImage()) {
            return imagef.ImageError.NoImageTypeAttachedToPixelTag;
        }
        switch(in_tag) {
            inline else => |tag| {
                const slice = try self.allocWithType(in_allocator, tag.toType(), count);
                self.pixels = @unionInit(PixelSlice, @tagName(tag), slice);
            },
        }
    }

    pub fn attachToBuffer(self: *PixelContainer, buffer: []u8, in_tag: PixelTag, count: usize) !void {
        if (!in_tag.canBeImage()) {
            return imagef.ImageError.NoImageTypeAttachedToPixelTag;
        }
        switch(in_tag) {
            inline else => |tag| {
                const slice = self.attachWithType(buffer, tag.toType(), count);
                self.pixels = @unionInit(PixelSlice, @tagName(tag), slice);
            },
        }
    }

    pub fn unattachFromBuffer(self: *PixelContainer) void {
        std.debug.assert(self.bytes != null and self.allocator == null);
        self.* = PixelContainer{};
    }

    pub fn free(self: *PixelContainer) void {
        if (self.bytes != null) {
            std.debug.assert(self.allocator != null);
            self.allocator.?.free(self.bytes.?);
        }
        self.* = PixelContainer{};
    }

    pub inline fn isEmpty(self: *const PixelContainer) bool {
        return self.bytes == null and self.allocator == null;
    }

    pub inline fn isValid(self: *const PixelContainer) bool {
        return self.bytes != null and self.allocator != null;
    }

    fn allocWithType(
        self: *PixelContainer, in_allocator: std.mem.Allocator, comptime PixelType: type, count: usize
    ) ![]PixelType {
        const sz = @sizeOf(PixelType) * count;
        self.allocator = in_allocator;
        self.bytes = try self.allocator.?.alloc(u8, sz);
        return @as([*]PixelType, @ptrCast(@alignCast(&self.bytes.?[0])))[0..count];
    }

    fn attachWithType(self: *PixelContainer, buffer: []u8, comptime PixelType: type, count: usize) []PixelType {
        self.allocator = null;
        self.bytes = buffer;
        return @as([*]PixelType, @ptrCast(@alignCast(&self.bytes.?[0])))[0..count];
    }

};

pub const ImageFileInfo = union(imagef.ImageFormat) {
    Bmp: bmp.BitmapInfo,
    Jpg: void,
    Png: void,
    Tga: tga.TgaInfo,
    Infer: void,
};

pub const Image = struct {
    width: u32 = 0,
    height: u32 = 0,
    px_container: PixelContainer = PixelContainer{},
    alpha: imagef.ImageAlpha = .None,
    file_info: ImageFileInfo = ImageFileInfo{ .Infer=undefined },

    pub fn init(
        self: *Image, 
        in_allocator: std.mem.Allocator, 
        type_tag: PixelTag, 
        width: u32, 
        height: u32, 
        in_alpha: imagef.ImageAlpha
    ) !void {
        if (!self.isEmpty()) {
            return imagef.ImageError.NotEmptyOnCreate;
        }
        self.width = width;
        self.height = height;
        try self.px_container.alloc(in_allocator, type_tag, self.len());
        // only matters for RGBA32 or if the alpha is premultiplied
        self.alpha = in_alpha;
    }

    pub fn clear(self: *Image) void {
        self.width = 0;
        self.height = 0;
        self.px_container.free();
        self.alpha = .None;
    }

    pub inline fn len(self: *const Image) usize {
        return @as(usize, @intCast(self.width)) * @as(usize, @intCast(self.height));
    }

    pub inline fn activePixelTag(self: *const Image) PixelTag {
        return std.meta.activeTag(self.px_container.pixels);
    }

    pub inline fn activeFileInfoTag(self: *const Image) imagef.ImageFormat {
        return std.meta.activeTag(self.file_info);
    }

    pub inline fn isEmpty(self: *const Image) bool {
        return self.px_container.isEmpty();
    }

    pub inline fn isValid(self: *const Image) bool {
        return self.px_container.isValid();
    }

    pub inline fn getBytes(self: *Image) []u8 {
        return self.px_container.bytes.?;
    }

    pub inline fn getBytesConst(self: *const Image) []const u8 {
        return self.px_container.bytes.?;
    }

    pub inline fn setBytesLen(self: *Image, new_len: usize) void {
        self.px_container.bytes.?.len = new_len;
    }

    // attach/unattach can cause a memory leak if you're manually unattaching from heap buffers. using attach/unattach 
    // with heap buffers is not recommended.
    pub fn attachToBuffer(self: *Image, buffer: []u8, type_tag: PixelTag, width: u32, height: u32) !void {
        if (!self.isEmpty()) {
            return imagef.ImageError.NotEmptyOnSetTypeTag;
        }
        self.width = width;
        self.height = height;
        try self.px_container.attachToBuffer(buffer, type_tag, self.len());
        self.alpha = .None;
    }

    // attach/unattach can cause a memory leak if you're manually unattaching from heap buffers. using attach/unattach 
    // with heap buffers is not recommended.
    pub fn unattachFromBuffer(self: *Image) void {
        self.width = 0;
        self.height = 0;
        self.px_container.unattachFromBuffer();
        self.alpha = .None;
    }

    pub fn getPixels(self: *const Image, comptime type_tag: PixelTag) !(std.meta.TagPayload(PixelSlice, type_tag)) {
        return switch(self.px_container.pixels) {
            type_tag => |slice| slice,
            else => imagef.ImageError.InactivePixelTag,
        };
    }

    pub inline fn XYToIdx(self: *const Image, x: u32, y: u32) usize {
        return y * self.width + x;
    }

    pub inline fn IdxToXY(self: *const Image, idx: u32) F32x2 {
        var vec: F32x2 = undefined;
        vec.y = idx / self.width;
        vec.x = idx - vec.y * self.width;
        return vec;
    }

};

pub const ImageLoadOptions = struct {

    local_path: bool = false,
    // for setting which file format are allowed (useful for redirecting load); Bmp, Jpg, Png, Tga
    input_format_allowed: [4]bool = .{ true, true, true, true },
    // for setting which pixel formats are allowed with functions; RGBA32, RGB16, R8, R16
    output_format_allowed: [4]bool = .{ true, true, true, true },

    pub fn setOnlyAllowedOutputFormat(self: *ImageLoadOptions, type_tag: PixelTag) !void {
        switch (type_tag) {
            .RGBA32, .RGB16, .R8, .R16 => {
                inline for (0..4) |i| {
                    self.output_format_allowed[i] = false;
                }
                self.output_format_allowed[@intFromEnum(type_tag)] = true;
            },
            else => return imagef.ImageError.NonImageFormatPassedIntoOptions,
        }
    }

    pub fn setOutputFormatAllowed(self: *ImageLoadOptions, type_tag: PixelTag) !void {
        switch (type_tag) {
            .RGBA32, .RGB16, .R8, .R16 => {
                self.output_format_allowed[@intFromEnum(type_tag)] = true;
            },
            else => return imagef.ImageError.NonImageFormatPassedIntoOptions,
        }
    }

    pub fn setOutputFormatDisallowed(self: *ImageLoadOptions, type_tag: PixelTag) !void {
        switch (type_tag) {
            .RGBA32, .RGB16, .R8, .R16 => {
                self.output_format_allowed[@intFromEnum(type_tag)] = false;
            },
            else => return imagef.ImageError.NonImageFormatPassedIntoOptions,
        }
    }

    pub fn setOnlyAllowedInputFormat(self: *ImageLoadOptions, format: imagef.ImageFormat) !void {
        switch (format) {
            .Bmp, .Jpg, .Png, .Tga => {
                inline for (0..4) |i| {
                    self.input_format_allowed[i] = false;
                }
                self.input_format_allowed[@intFromEnum(format)] = true;
            },
            else => return imagef.ImageError.NonImageFormatPassedIntoOptions,
        }
    }

    pub fn setInputFormatAllowed(self: *ImageLoadOptions, format: imagef.ImageFormat) !void {
        if (format == .Infer) {
            return imagef.ImageError.NonImageFormatPassedIntoOptions;
        }
        self.input_format_allowed[@intFromEnum(format)] = true;
    }

    pub fn setInputFormatDisallowed(self: *ImageLoadOptions, format: imagef.ImageFormat) !void {
        if (format == .Infer) {
            return imagef.ImageError.NonImageFormatPassedIntoOptions;
        }
        self.input_format_allowed[@intFromEnum(format)] = false;
    }

    pub inline fn isInputFormatAllowed(self: *const ImageLoadOptions, format: imagef.ImageFormat) bool {
        if (format == .Infer) {
            return false;
        }
        return self.input_format_allowed[@intFromEnum(format)];
    }

    pub inline fn isOutputFormatAllowed(self: *const ImageLoadOptions, type_tag: PixelTag) bool {
        switch (type_tag) {
            .RGBA32, .RGB16, .R8, .R16 => {
                return self.output_format_allowed[@intFromEnum(type_tag)];
            },
            else => return false,
        }
    }
};

pub const ImageSaveOptions = struct {
    local_path: bool = false,
    alpha: imagef.SaveAlpha = .UseImageAlpha,
    // for setting which pixel formats are allowed with functions; RGBA32, RGB16, R8, R16
    output_format_allowed: [4]bool = .{ true, true, true, true },
    strategy: imagef.SaveStrategy = .Small, 

    pub fn setOnlyAllowedOutputFormat(self: *ImageSaveOptions, type_tag: PixelTag) !void {
        switch (type_tag) {
            .RGBA32, .RGB16, .R8, .R16 => {
                inline for (0..4) |i| {
                    self.output_format_allowed[i] = false;
                }
                self.output_format_allowed[@intFromEnum(type_tag)] = true;
            },
            else => return imagef.ImageError.NonImageFormatPassedIntoOptions,
        }
    }

    pub fn setOutputFormatAllowed(self: *ImageSaveOptions, type_tag: PixelTag) !void {
        switch (type_tag) {
            .RGBA32, .RGB16, .R8, .R16 => {
                self.output_format_allowed[@intFromEnum(type_tag)] = true;
            },
            else => return imagef.ImageError.NonImageFormatPassedIntoOptions,
        }
    }

    pub fn setOutputFormatDisallowed(self: *ImageSaveOptions, type_tag: PixelTag) !void {
        switch (type_tag) {
            .RGBA32, .RGB16, .R8, .R16 => {
                self.output_format_allowed[@intFromEnum(type_tag)] = false;
            },
            else => return imagef.ImageError.NonImageFormatPassedIntoOptions,
        }
    }

    pub inline fn isOutputFormatAllowed(self: *const ImageSaveOptions, type_tag: PixelTag) bool {
        switch (type_tag) {
            .RGBA32, .RGB16, .R8, .R16 => {
                return self.output_format_allowed[@intFromEnum(type_tag)];
            },
            else => return false,
        }
    }
};

