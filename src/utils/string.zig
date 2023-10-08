const std = @import("std");

pub fn LocalStringBuffer(comptime sz: comptime_int) type {

    return struct {
        const LSBufType = @This();

        bytes: [sz]u8 = undefined,
        len: usize = 0,
        anchor_len: usize = 0,

        pub inline fn new() LSBufType {
            return LSBufType{};
        }

        pub inline fn append(self: *LSBufType, append_str: []const u8) StringError!void {
            const new_len = self.len + append_str.len;
            try copyToBuffer(append_str, self.bytes[self.len..]);
            self.len = new_len;
        }

        pub inline fn appendLower(self: *LSBufType, append_str: []const u8) StringError!void {
            const new_len = self.len + append_str.len;
            try copyLowerToBuffer(append_str, self.bytes[self.len..]);
            self.len = new_len;
        }

        pub inline fn replace(self: *LSBufType, replace_str: []const u8) StringError!void {
            const new_len = replace_str.len;
            try copyToBuffer(replace_str, self.bytes[0..new_len]);
            self.len = new_len;
        }

        pub inline fn replaceLower(self: *LSBufType, replace_str: []const u8) StringError!void {
            const new_len = replace_str.len;
            try copyLowerToBuffer(replace_str, self.bytes[0..new_len]);
            self.len = new_len;
        }

        pub inline fn empty(self: *LSBufType) void {
            self.len = 0;
            self.anchor_len = 0;
        }

        pub fn appendHex(self: *LSBufType, append_str: []const u8, byte_spaces: bool) StringError!void {
            if (append_str.len == 0) {
                return;
            }
            if (byte_spaces) {
                const new_len = (self.len + append_str.len * 3) - 1;
                if (new_len > self.bytes.len) {
                    return StringError.BufferTooShort;
                }
            }
            else {
                const new_len = self.len + append_str.len * 2;
                if (new_len > self.bytes.len) {
                    return StringError.BufferTooShort;
                }
            }
            
            var buf_pos: usize = self.len;
            for (0..append_str.len) |i| {
                var nibbles: [2]u8 = .{ (append_str[i] & 0xf0) >> 4, append_str[i] & 0x0f };
                inline for (0..2) |j| {
                    if (nibbles[j] <= 9) {
                        self.bytes[buf_pos] = nibbles[j] + to_numchar_diff;
                    }
                    else {
                        self.bytes[buf_pos] = nibbles[j] + to_hexletter_diff;
                    }
                    buf_pos += 1;
                }
                if (i < append_str.len - 1 and byte_spaces) {
                    self.bytes[buf_pos] = ' ';
                    buf_pos += 1;
                }
            }
            self.len = buf_pos;
        }

        // for now, assuming decimal
        pub fn appendUnsignedNumber(self: *LSBufType, append_num: anytype) StringError!void {
            // const negative = append_num < 0;
            // append_num = std.math.absInt(append_num);
            var reverse_buf: [21]u8 = undefined;
            var i: usize = 20;
            var num = append_num;
            while (i >= 0) : (i -= 1) {
                var remainder = num % 10;
                var next_num = num / 10;
                if (next_num > 0) {
                    reverse_buf[i] = @as(u8, @intCast(remainder)) + to_numchar_diff;
                }
                else {
                    reverse_buf[i] = @as(u8, @intCast(num)) + to_numchar_diff;
                    break;
                }
                num = next_num;
            }
            // if (negative and i > 0) {
            //     i -= 1;
            //     reverse_buf[i] = '-';
            // }
            const number_slice = reverse_buf[i..21];
            const new_len = self.len + number_slice.len;
            try copyToBuffer(number_slice, self.bytes[self.len..]);
            self.len = new_len;
        }

        pub fn appendChar(self: *LSBufType, append_char: u8) StringError!void {
            const new_len = self.len + 1;
            if (new_len > self.bytes.len) {
                return StringError.BufferTooShort;
            }
            self.bytes[self.len] = append_char;
            self.len = new_len;
        }

        pub inline fn setAnchor(self: *LSBufType) void {
            self.anchor_len = self.len;
        }

        pub inline fn revertToAnchor(self: *LSBufType) void {
            self.len = self.anchor_len;
        }

        pub inline fn string(self: *const LSBufType) []const u8 {
            return self.bytes[0..self.len];
        }

    };
}

pub fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) {
        return false;
    }
    for (0..a.len) |i| {
        if (a[i] != b[i]) {
            return false;
        }
    }
    return true;
}

// returns how many characters are equal, starting from the beginning
pub fn sameCount(a: []const u8, b: []const u8) usize {
    var eql_ct: usize = 0;
    for (0..@min(a.len, b.len)) |i| {
        if (a[i] != b[i]) { 
            break;
        }
        eql_ct += 1;
    }
    return eql_ct;
}

pub fn sameTail(a: []const u8, b: []const u8) bool {
    if (a.len < b.len) {
        const b_start = b.len - a.len;
        const b_end = b[b_start..];
        for (0..a.len) |i| {
            if (a[i] != b_end[i]) {
                return false;
            }
        }
        return true;
    }
    else {
        const a_start = a.len - b.len;
        const a_end = a[a_start..];
        for (0..b.len) |i| {
            if (a_end[i] != b[i]) {
                return false;
            }
        }
        return true;
    }
}

pub inline fn sameHead(a: []const u8, b: []const u8) bool {
    for (0..@min(a.len, b.len)) |i| {
        if (a[i] != b[i]) {
            return false;
        }
    }
    return true;
}

pub inline fn findL(str: []const u8, token: u8) ?usize {
    for (0..str.len) |i| {
        if (str[i] == token) {
            return i;
        }
    }
    return null;
}

pub inline fn findR(str: []const u8, token: u8) ?usize {
    var i: usize = str.len - 1;
    while (i >= 0) : (i -= 1) {
        if (str[i] == token) {
            return i;
        }
    }
    return null;
}

// TODO: generalized copy
pub inline fn copy(str: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var new_str: []u8 = try allocator.alloc(u8, str.len);
    @memcpy(new_str[0..str.len], str[0..str.len]);
    return new_str;
}

pub fn copyLower(str: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var new_str: []u8 = try allocator.alloc(u8, str.len);
    for (0..str.len) |i| {
        if (str[i] >= 'A' and str[i] <= 'Z') {
            new_str[i] = str[i] + to_lower_diff;
        }
        else {
            new_str[i] = str[i];
        }
    }
    return new_str;
}

pub inline fn copyToBuffer(str: []const u8, buffer: []u8) StringError!void {
    if (buffer.len < str.len) {
        return StringError.BufferTooShort;
    }
    @memcpy(buffer[0..str.len], str[0..str.len]);
}

pub fn copyLowerToBuffer(str: []const u8, buffer: []u8) StringError!void {
    if (buffer.len < str.len) {
        return StringError.BufferTooShort;
    }
    for (0..str.len) |i| {
        const char = str[i];
        if (char >= 'A' and char <= 'Z') {
            buffer[i] = char + to_lower_diff;
        }
        else {
            buffer[i] = char;
        }
    }
}

pub inline fn free(str: []u8, allocator: std.mem.Allocator) void {
    allocator.free(str);
}

pub fn toLower(str: []u8) void {
    for (str) |*char| {
        if (char.* >= 'A' and char.* <= 'Z') {
            char.* += to_lower_diff;
        }
    }
}

const StringError = error{
    BufferTooShort
};

const to_lower_diff: comptime_int = 'a' - 'A';
const to_numchar_diff: comptime_int = '0';
const to_hexletter_diff: comptime_int = 'a' - 10;
