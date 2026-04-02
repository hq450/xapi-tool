const std = @import("std");

pub const Error = error{
    InvalidLength,
    InvalidWireType,
    Overflow,
    UnexpectedEof,
};

pub const WireType = enum(u3) {
    varint = 0,
    fixed64 = 1,
    length_delimited = 2,
    start_group = 3,
    end_group = 4,
    fixed32 = 5,
};

pub const Field = struct {
    number: u64,
    wire_type: WireType,
};

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    pub fn eof(self: Reader) bool {
        return self.pos >= self.data.len;
    }

    pub fn readField(self: *Reader) Error!Field {
        const raw = try self.readVarint();
        const wire = switch (raw & 0x07) {
            0 => WireType.varint,
            1 => WireType.fixed64,
            2 => WireType.length_delimited,
            3 => WireType.start_group,
            4 => WireType.end_group,
            5 => WireType.fixed32,
            else => return error.InvalidWireType,
        };
        return .{ .number = raw >> 3, .wire_type = wire };
    }

    pub fn readVarint(self: *Reader) Error!u64 {
        var value: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (self.pos >= self.data.len) return error.UnexpectedEof;
            const byte = self.data[self.pos];
            self.pos += 1;
            value |= (@as(u64, byte & 0x7f) << shift);
            if ((byte & 0x80) == 0) return value;
            if (shift >= 63) return error.Overflow;
            shift += 7;
        }
    }

    pub fn readBytes(self: *Reader) Error![]const u8 {
        const len_u64 = try self.readVarint();
        const len = std.math.cast(usize, len_u64) orelse return error.InvalidLength;
        if (len > self.data.len - self.pos) return error.UnexpectedEof;
        const bytes = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return bytes;
    }

    pub fn skip(self: *Reader, wire_type: WireType) Error!void {
        switch (wire_type) {
            .varint => _ = try self.readVarint(),
            .fixed64 => try self.skipBytes(8),
            .length_delimited => _ = try self.readBytes(),
            .fixed32 => try self.skipBytes(4),
            .start_group, .end_group => return error.InvalidWireType,
        }
    }

    fn skipBytes(self: *Reader, len: usize) Error!void {
        if (len > self.data.len - self.pos) return error.UnexpectedEof;
        self.pos += len;
    }
};

pub const Writer = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, list: *std.ArrayList(u8)) Writer {
        return .{ .allocator = allocator, .list = list };
    }

    pub fn writeTag(self: *Writer, number: u64, wire_type: WireType) !void {
        try self.writeVarint((number << 3) | @intFromEnum(wire_type));
    }

    pub fn writeVarint(self: *Writer, value_in: u64) !void {
        var value = value_in;
        while (value >= 0x80) {
            try self.list.append(self.allocator, @intCast((value & 0x7f) | 0x80));
            value >>= 7;
        }
        try self.list.append(self.allocator, @intCast(value));
    }

    pub fn writeBool(self: *Writer, field_number: u64, value: bool) !void {
        try self.writeTag(field_number, .varint);
        try self.writeVarint(if (value) 1 else 0);
    }

    pub fn writeString(self: *Writer, field_number: u64, value: []const u8) !void {
        try self.writeTag(field_number, .length_delimited);
        try self.writeVarint(value.len);
        try self.list.appendSlice(self.allocator, value);
    }

    pub fn writeMessage(self: *Writer, field_number: u64, bytes: []const u8) !void {
        try self.writeTag(field_number, .length_delimited);
        try self.writeVarint(bytes.len);
        try self.list.appendSlice(self.allocator, bytes);
    }
};

test "writer and reader roundtrip simple string" {
    var list = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer list.deinit(std.testing.allocator);
    var writer = Writer.init(std.testing.allocator, &list);
    try writer.writeString(1, "hello");

    var reader = Reader.init(list.items);
    const field = try reader.readField();
    try std.testing.expectEqual(@as(u64, 1), field.number);
    try std.testing.expectEqual(WireType.length_delimited, field.wire_type);
    try std.testing.expectEqualStrings("hello", try reader.readBytes());
    try std.testing.expect(reader.eof());
}
