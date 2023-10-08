const std = @import("std");

const print = std.debug.print;
const assert = std.debug.assert;
const expect = std.testing.expect;

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// -------------------------------------------------------------------------------------------------------- Local Buffer
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

pub fn LocalBuffer(comptime ItemType: type, comptime buflen: usize) type {
    assert(buflen > 0);
    return struct {
        const Self = @This();

        buffer: [buflen]ItemType = undefined,
        len: usize = 0,

        pub inline fn new() Self {
            return Self{};
        }

        pub fn ptr(self: *Self) [*]ItemType {
            return @ptrCast(&self.buffer[0]);
        }
        
        pub fn cptr(self: *Self) [*c]ItemType {
            return @ptrCast(&self.buffer[0]);
        }

        pub inline fn items(self: *Self) []ItemType {
            return self.buffer[0..self.len];
        }

        pub inline fn constItems(self: *const Self) []const ItemType {
            return self.buffer[0..self.len];
        }
        
        pub inline fn zeroItems(self: *Self) void {
            @memset(self.buffer[0..self.len], std.mem.zeroes(ItemType));
        }

        /// set any non-default values within all structs in the array to 0 and set the count to the capacity
        pub fn zeroDefaultItems(self: *Self) void {
            for (self.buffer[0..self.len]) |*item| {
                item.* = std.mem.zeroInit(ItemType, .{});
            }
        }

        pub inline fn setItems(self: *Self, item: ItemType) void {
            @memset(self.buffer[0..self.len], item);
        }

        pub inline fn zeroFill(self: *Self) void {
            self.len = buflen;
            self.zeroItems();
        }

        pub inline fn zeroDefaultFill(self: *Self) void {
            self.len = buflen;
            self.zeroDefaultItems();
        }

        /// fill the array with this value and set the count to capacity
        pub inline fn fill(self: *Self, fill_item: ItemType) void {
            self.len = buflen;
            self.setItems(fill_item);
        }

        pub inline fn capacity() usize {
            return buflen;
        }

        pub inline fn setLen(self: *Self, new_len: usize) void {
            assert(new_len <= buflen);
            self.len = new_len;
        }

        pub inline fn expandToCapacity(self: *Self) void {
            self.len = buflen;
        }

        /// set the count to 0
        pub inline fn clear(self: *Self) void {
            self.len = 0;
        }

        /// push an item onto the array and increase the count.
        pub inline fn append(self: *Self, new_item: ItemType) void {
            assert(self.len < buflen);
            self.buffer[self.len] = new_item;
            self.len += 1;
        }

        pub fn insert(self: *Self, new_item: ItemType, idx: usize) void {
            assert(self.len < buflen);
            for (idx..self.len) |i| {
                self.buffer[i + 1] = self.buffer[i];
            }
            self.buffer[idx] = new_item;
            self.len += 1;
        }

        pub fn orderedInsert(self: *Self, new_item: ItemType) void {
            assert(self.len < buflen);
            for (0..self.len) |i| {
                if (new_item < self.buffer[i]) {
                    self.insert(new_item, i);
                    return;
                }
            }
            self.append(new_item);
        }

        pub fn compareInsert(self: *Self, new_item: ItemType) void {
            assert(self.len < buflen);
            for (0..self.len) |i| {
                if (new_item.compare(self.buffer[i])) {
                    self.insert(new_item, i);
                    return;
                }
            }
            self.append(new_item);
        }

        pub inline fn appendNTimes(self: *Self, new_item: ItemType, n: usize) void {
            const new_len = self.len + n;
            assert(new_len <= buflen);
            @memset(self.buffer[self.len..new_len], new_item);
            self.len = new_len;
        }

        pub inline fn appendSlice(self: *Self, new_items: []const ItemType) void {
            const new_len = self.len + new_items.len;
            assert(new_len <= buflen);
            @memcpy(self.buffer[self.len..new_len], new_items);
            self.len = new_len;
        }

        /// get the last item on the array and decrease the count.
        pub fn pop(self: *Self) ItemType {
            assert(self.len > 0);
            self.len -= 1;
            const val = self.buffer[self.len];
            return val;
        }

        pub fn popOrNull(self: *Self) ?ItemType {
            if (self.len == 0) {
                return null;
            }
            return self.pop();
        }

        pub fn getLast(self: *Self) ItemType {
            assert(self.len > 0);
            const val = self.buffer[self.len - 1];
            return val;
        }

        pub fn getLastOrNull(self: *Self) ?ItemType {
            if (self.len == 0) {
                return null;
            }
            return self.getLast();
        }

        /// remove the item at this index (order is not retained).
        pub inline fn swapRemove(self: *Self, idx: usize) void {
            assert(idx < self.len);
            self.len -= 1;
            if (idx != self.len) {
                self.buffer[idx] = self.buffer[self.len];
            }
        }

        /// remove the item at this index while retaining order.
        pub fn orderedRemove(self: *Self, idx: usize) void {
            assert(idx < self.items.len);
            self.len -= 1;
            for (idx..self.len) |i| {
                self.buffer[i] = self.buffer[i + 1];
            }
        }

        /// given a pointer to an item, remove the item from the array (order is not retained).
        pub inline fn itemRemove(self: *Self, item: *const ItemType) void {
            const idx = self.indexOf(item);
            self.swapRemove(idx);
        }

        /// given a pointer to an item, remove the item from the array while retaining order.
        pub inline fn orderedItemRemove(self: *Self, item: *const ItemType) void {
            const idx = self.indexOf(item);
            self.orderedRemove(idx);
        }

        pub fn indexOf(self: *const Self, array_item: *const ItemType) usize {
            const array_address: i64 = @intFromPtr(&self.buffer[0]);
            const item_address: i64 = @intFromPtr(array_item);
            const item_diff = item_address - array_address;
            const idx = @divExact(item_diff, @as(i64, @intCast(@sizeOf(ItemType))));
            assert(idx >= 0 and idx < self.ct);
            return @intCast(idx);
        }

        pub inline fn find(self: *const Self, item: ItemType) ?usize {
            return self.findFrom(item, 0);
        }

        pub inline fn findReverse(self: *const Self, item: ItemType) ?usize {
            return self.findFromReverse(item, self.len - 1);
        }

        pub fn findFrom(self: *const Self, item: ItemType, idx: usize) ?usize {
            assert(idx < self.len);
            for (idx..self.len) |i| {
                if (std.meta.eql(self.buffer[i], item)) {
                    return idx;
                }
            }
            return null;
        }

        pub fn findFromReverse(self: *const Self,  item: ItemType, idx: usize) ?usize {
            assert(idx < self.len);
            var i = idx;
            while (i >= 0) : (i -= 1) {
                if (std.meta.eql(self.buffer[i], item)) {
                    return i;
                }
            }
            return null;
        }
    };
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// -------------------------------------------------------------------------------------------------------------- errors
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

const ArrayError = error {
    BufferTooSmall,
    BufferEmpty,
};

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// ---------------------------------------------------------------------------------------------------------------- test
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

test "new structure [array]" {
    var arr = LocalBuffer(u32, 10).new();
    arr.expandToCapacity();
    arr.zeroItems();
    arr.setItems(18);
    arr.items()[1] = 8;
    arr.clear();
    arr.append(22);
    arr.expandToCapacity();
    // arr.zeroFill();
    // arr.fill(8);
    print("{any}\n", .{arr.items()});
}
