const std = @import("std");
const string = @import("string.zig");

const LocalStringBuffer = string.LocalStringBuffer;

pub const ImageFileError = error {
    FullPathTooLong,
    InvalidFileSize,
    UnableToInferFormat
};

pub fn getFullPath(
    buffer: *LocalStringBuffer(std.fs.MAX_PATH_BYTES + std.fs.MAX_NAME_BYTES), 
    path: []const u8, 
    file_name: []const u8, 
    path_is_local: bool, 
    path_step: PathStep
) ![]const u8 {
    if (path_step == .Full or path_step == .Directory) {
        buffer.empty();
        if (path.len > std.fs.MAX_PATH_BYTES) {
            return ImageFileError.FullPathTooLong;
        }
        if (path_is_local) {
            const real_path: []u8 = try std.fs.cwd().realpath(path, buffer.bytes[0..std.fs.MAX_PATH_BYTES]);
            buffer.len = real_path.len;
        } else {
            try buffer.append(path);
        }
        if (buffer.len + file_name.len + 1 > buffer.bytes.len) {
            return ImageFileError.FullPathTooLong;
        }
    }

    if (path_step == .Full or path_step == .File) {
        try buffer.append("/");
        try buffer.append(file_name);
    }

    return buffer.string();
}

// try to determine whether a file is bmp, png, etc...
// file ptr will always be at byte 0 after calling
pub inline fn inferImageFormat(file: *std.fs.File, file_path: []const u8) !ImageFormat {
    try file.seekTo(0);
    var format = try inferImageFormatFromExtension(file_path);
    if (format != .Infer) {
        return format;
    }
    format = try inferImageFormatFromFile(file);
    try file.seekTo(0);
    return format;
}

pub fn inferImageFormatFromExtension(file_path: []const u8) !ImageFormat {
    var extension_idx: ?usize = string.findR(file_path, '.');
    if (extension_idx == null) {
        return .Infer;
    }

    extension_idx.? += 1;
    const extension_len = file_path.len - extension_idx.?;
    if (extension_len > 4 or extension_len < 3) {
        return .Infer;
    }

    const extension: []const u8 = file_path[extension_idx.?..];
    var extension_lower_buf = LocalStringBuffer(4).new();
    try extension_lower_buf.appendLower(extension);
    const extension_lower = extension_lower_buf.string();

    if (string.same(extension_lower, "bmp") or string.same(extension_lower, "dib")) {
        return ImageFormat.Bmp;
    } else if (string.same(extension_lower, "tga") 
        or string.same(extension_lower, "icb") 
        or string.same(extension_lower, "vda") 
        or string.same(extension_lower, "vst") 
        or string.same(extension_lower, "tpic")
    ) {
        return ImageFormat.Tga;
    } else if (string.same(extension_lower, "png")) {
        return ImageFormat.Png;
    } else if (string.same(extension_lower, "jpg") or string.same(extension_lower, "jpeg")) {
        return ImageFormat.Jpg;
    } else {
        return .Infer;
    }
}

pub fn inferImageFormatFromFile(file: *std.fs.File) !ImageFormat {
    const stat = try file.stat();
    if (stat.size < 8) {
        return ImageFileError.InvalidFileSize;
    }

    const header_buffer: [8]u8 = try file.reader().readBytesNoEof(8);
    if (string.same(bmp_identifier, header_buffer[0..2])) {
        return ImageFormat.Bmp;
    } else if (string.same(png_identifier, header_buffer[0..8])) {
        return ImageFormat.Png;
    } else if (stat.size >= tga_signature_end_offset) {
        const tga_footer_begin = stat.size - tga_signature_end_offset;
        try file.seekTo(tga_footer_begin);
        const tga_signature: [16]u8 = try file.reader().readBytesNoEof(16);
        if (string.same(tga_identifier, &tga_signature)) {
            return ImageFormat.Tga;
        }
    }

    return ImageFileError.UnableToInferFormat;
}

// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// ----------------------------------------------------------------------------------------------------------- constants
// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

pub const bmp_identifier: *const [2:0]u8 = "BM";
pub const png_identifier = "\x89PNG\x0d\x0a\x1a\x0a";
pub const tga_identifier = "TRUEVISION-XFILE";
pub const tga_signature_end_offset = 18;

// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// --------------------------------------------------------------------------------------------------------------- enums
// /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

const PathStep = enum { Full, Directory, File };

pub const ImageFormat = enum { Bmp, Jpg, Png, Tga, Infer };
