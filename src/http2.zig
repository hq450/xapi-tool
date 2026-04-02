const std = @import("std");

pub const client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

pub const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,
};

pub const flags = struct {
    pub const end_stream: u8 = 0x1;
    pub const ack: u8 = 0x1;
    pub const end_headers: u8 = 0x4;
};

pub const FrameHeader = struct {
    length: u32,
    frame_type: FrameType,
    frame_flags: u8,
    stream_id: u32,
};

pub const default_max_frame_size: usize = 16 * 1024;

pub fn writeFrame(stream: std.net.Stream, frame_type: FrameType, frame_flags: u8, stream_id: u32, payload: []const u8) !void {
    if (payload.len > 0x00ff_ffff) return error.FrameTooLarge;

    var header: [9]u8 = undefined;
    header[0] = @intCast((payload.len >> 16) & 0xff);
    header[1] = @intCast((payload.len >> 8) & 0xff);
    header[2] = @intCast(payload.len & 0xff);
    header[3] = @intFromEnum(frame_type);
    header[4] = frame_flags;
    const sid = stream_id & 0x7fff_ffff;
    header[5] = @intCast((sid >> 24) & 0x7f);
    header[6] = @intCast((sid >> 16) & 0xff);
    header[7] = @intCast((sid >> 8) & 0xff);
    header[8] = @intCast(sid & 0xff);
    try stream.writeAll(&header);
    try stream.writeAll(payload);
}

pub fn writeDataFrames(stream: std.net.Stream, stream_id: u32, payload: []const u8, end_stream: bool) !void {
    var offset: usize = 0;
    if (payload.len == 0) {
        try writeFrame(stream, .data, if (end_stream) flags.end_stream else 0, stream_id, "");
        return;
    }
    while (offset < payload.len) {
        const remaining = payload.len - offset;
        const chunk_len = @min(remaining, default_max_frame_size);
        const chunk = payload[offset .. offset + chunk_len];
        offset += chunk_len;
        var frame_flags: u8 = 0;
        if (end_stream and offset >= payload.len) {
            frame_flags |= flags.end_stream;
        }
        try writeFrame(stream, .data, frame_flags, stream_id, chunk);
    }
}

pub fn readFrameHeader(stream: std.net.Stream) !FrameHeader {
    var header: [9]u8 = undefined;
    const got = try stream.readAtLeast(&header, header.len);
    if (got != header.len) return error.UnexpectedEof;
    return .{
        .length = (@as(u32, header[0]) << 16) | (@as(u32, header[1]) << 8) | @as(u32, header[2]),
        .frame_type = @enumFromInt(header[3]),
        .frame_flags = header[4],
        .stream_id = ((@as(u32, header[5]) & 0x7f) << 24) | (@as(u32, header[6]) << 16) | (@as(u32, header[7]) << 8) | @as(u32, header[8]),
    };
}

pub fn readPayloadAlloc(allocator: std.mem.Allocator, stream: std.net.Stream, len: usize) ![]u8 {
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    const got = try stream.readAtLeast(buf, len);
    if (got != len) return error.UnexpectedEof;
    return buf;
}
