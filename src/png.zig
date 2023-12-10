const std = @import("std");
const imagef = @import("image.zig");
const types = @import("types.zig");
const Image = types.Image;

pub fn load(
    file: *std.fs.File, image: *Image, allocator: std.mem.Allocator, options: *const types.ImageLoadOptions
) !void {
    _ = file;
    _ = image;
    _ = allocator;
    _ = options;
}