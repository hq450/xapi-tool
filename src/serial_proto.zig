const std = @import("std");
const pb = @import("pb.zig");

pub const TypedMessage = struct {
    type_name: []const u8,
    value: []const u8,

    pub fn encode(self: TypedMessage, allocator: std.mem.Allocator) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer out.deinit(allocator);
        var writer = pb.Writer.init(allocator, &out);
        try writer.writeString(1, self.type_name);
        try writer.writeMessage(2, self.value);
        return out.toOwnedSlice(allocator);
    }
};
