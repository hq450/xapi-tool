const std = @import("std");

fn appendInt(allocator: std.mem.Allocator, dst: *std.ArrayList(u8), first_prefix_bits: u8, prefix_value: u8, value_in: usize) !void {
    var value = value_in;
    const Shift = std.math.Log2Int(usize);
    const max_prefix = (@as(usize, 1) << @as(Shift, @intCast(first_prefix_bits))) - 1;
    if (value < max_prefix) {
        try dst.append(allocator, prefix_value | @as(u8, @intCast(value)));
        return;
    }

    try dst.append(allocator, prefix_value | @as(u8, @intCast(max_prefix)));
    value -= max_prefix;
    while (value >= 128) {
        try dst.append(allocator, @as(u8, @intCast((value & 0x7f) | 0x80)));
        value >>= 7;
    }
    try dst.append(allocator, @as(u8, @intCast(value)));
}

fn appendString(allocator: std.mem.Allocator, dst: *std.ArrayList(u8), value: []const u8) !void {
    try appendInt(allocator, dst, 7, 0x00, value.len);
    try dst.appendSlice(allocator, value);
}

pub fn appendLiteralHeaderNoIndex(allocator: std.mem.Allocator, dst: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    try appendInt(allocator, dst, 4, 0x00, 0);
    try appendString(allocator, dst, name);
    try appendString(allocator, dst, value);
}

pub fn encodeRequestHeaders(allocator: std.mem.Allocator, authority: []const u8, path: []const u8, user_agent: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    try appendLiteralHeaderNoIndex(allocator, &out, ":method", "POST");
    try appendLiteralHeaderNoIndex(allocator, &out, ":scheme", "http");
    try appendLiteralHeaderNoIndex(allocator, &out, ":path", path);
    try appendLiteralHeaderNoIndex(allocator, &out, ":authority", authority);
    try appendLiteralHeaderNoIndex(allocator, &out, "content-type", "application/grpc");
    try appendLiteralHeaderNoIndex(allocator, &out, "te", "trailers");
    try appendLiteralHeaderNoIndex(allocator, &out, "user-agent", user_agent);

    return out.toOwnedSlice(allocator);
}
