const std = @import("std");
const pb = @import("pb.zig");

pub const OutboundHandlerConfig = struct {
    tag: []const u8,
    sender_settings: ?[]const u8 = null,
    proxy_settings: []const u8,

    pub fn encode(self: OutboundHandlerConfig, allocator: std.mem.Allocator) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer out.deinit(allocator);
        var writer = pb.Writer.init(allocator, &out);
        try writer.writeString(1, self.tag);
        if (self.sender_settings) |sender| try writer.writeMessage(2, sender);
        try writer.writeMessage(3, self.proxy_settings);
        return out.toOwnedSlice(allocator);
    }
};
