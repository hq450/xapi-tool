const std = @import("std");

pub fn frameMessage(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    try out.append(allocator, 0);
    try out.append(allocator, @intCast((payload.len >> 24) & 0xff));
    try out.append(allocator, @intCast((payload.len >> 16) & 0xff));
    try out.append(allocator, @intCast((payload.len >> 8) & 0xff));
    try out.append(allocator, @intCast(payload.len & 0xff));
    try out.appendSlice(allocator, payload);
    return out.toOwnedSlice(allocator);
}

pub fn extractUnaryMessage(data: []const u8) ![]const u8 {
    if (data.len < 5) return error.InvalidGrpcFrame;
    if (data[0] != 0) return error.CompressedGrpcMessageUnsupported;

    const len = (@as(u32, data[1]) << 24) |
        (@as(u32, data[2]) << 16) |
        (@as(u32, data[3]) << 8) |
        @as(u32, data[4]);

    if (data.len < 5 + len) return error.InvalidGrpcFrame;
    return data[5 .. 5 + len];
}

test "grpc frame roundtrip" {
    const payload = "abc";
    const framed = try frameMessage(std.testing.allocator, payload);
    defer std.testing.allocator.free(framed);
    try std.testing.expectEqualStrings(payload, try extractUnaryMessage(framed));
}
