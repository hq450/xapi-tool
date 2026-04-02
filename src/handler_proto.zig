const std = @import("std");
const pb = @import("pb.zig");
const serial_proto = @import("serial_proto.zig");
const core_proto = @import("core_proto.zig");

pub const RemoveOutboundRequest = struct {
    tag: []const u8,

    pub fn encode(self: RemoveOutboundRequest, allocator: std.mem.Allocator) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer out.deinit(allocator);
        var writer = pb.Writer.init(allocator, &out);
        try writer.writeString(1, self.tag);
        return out.toOwnedSlice(allocator);
    }
};

pub const AddOutboundRequest = struct {
    tag: []const u8,
    proxy_type: []const u8,
    proxy_value: []const u8,
    sender_type: ?[]const u8 = null,
    sender_value: ?[]const u8 = null,

    pub fn encode(self: AddOutboundRequest, allocator: std.mem.Allocator) ![]u8 {
        const proxy_settings_message = serial_proto.TypedMessage{
            .type_name = self.proxy_type,
            .value = self.proxy_value,
        };
        const proxy_settings = try proxy_settings_message.encode(allocator);
        defer allocator.free(proxy_settings);

        var sender_settings: ?[]const u8 = null;
        defer if (sender_settings) |v| allocator.free(v);
        if (self.sender_type) |sender_type| {
            const sender_value = self.sender_value orelse return error.InvalidArguments;
            const sender_settings_message = serial_proto.TypedMessage{
                .type_name = sender_type,
                .value = sender_value,
            };
            sender_settings = try sender_settings_message.encode(allocator);
        }

        const outbound_config = core_proto.OutboundHandlerConfig{
            .tag = self.tag,
            .sender_settings = sender_settings,
            .proxy_settings = proxy_settings,
        };
        const outbound = try outbound_config.encode(allocator);
        defer allocator.free(outbound);

        var out = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer out.deinit(allocator);
        var writer = pb.Writer.init(allocator, &out);
        try writer.writeMessage(1, outbound);
        return out.toOwnedSlice(allocator);
    }
};
