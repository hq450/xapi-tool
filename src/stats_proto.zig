const std = @import("std");
const pb = @import("pb.zig");

pub const Stat = struct {
    name: []u8,
    value: i64,
};

pub const QueryStatsRequest = struct {
    pattern: []const u8,
    reset: bool = false,

    pub fn encode(self: QueryStatsRequest, allocator: std.mem.Allocator) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer out.deinit(allocator);

        var writer = pb.Writer.init(allocator, &out);
        if (self.pattern.len > 0) try writer.writeString(1, self.pattern);
        if (self.reset) try writer.writeBool(2, true);
        return out.toOwnedSlice(allocator);
    }
};

pub const QueryStatsResponse = struct {
    stats: []Stat,

    pub fn deinit(self: QueryStatsResponse, allocator: std.mem.Allocator) void {
        for (self.stats) |stat| allocator.free(stat.name);
        allocator.free(self.stats);
    }

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) !QueryStatsResponse {
        var reader = pb.Reader.init(data);
        var stats = try std.ArrayList(Stat).initCapacity(allocator, 0);
        errdefer {
            for (stats.items) |stat| allocator.free(stat.name);
            stats.deinit(allocator);
        }

        while (!reader.eof()) {
            const field = try reader.readField();
            switch (field.number) {
                1 => {
                    if (field.wire_type != .length_delimited) return error.InvalidWireType;
                    const stat_bytes = try reader.readBytes();
                    try stats.append(allocator, try decodeStat(allocator, stat_bytes));
                },
                else => try reader.skip(field.wire_type),
            }
        }

        return .{ .stats = try stats.toOwnedSlice(allocator) };
    }
};

fn decodeStat(allocator: std.mem.Allocator, data: []const u8) !Stat {
    var reader = pb.Reader.init(data);
    var name: []u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(name);
    var value: i64 = 0;

    while (!reader.eof()) {
        const field = try reader.readField();
        switch (field.number) {
            1 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                allocator.free(name);
                name = try allocator.dupe(u8, try reader.readBytes());
            },
            2 => {
                if (field.wire_type != .varint) return error.InvalidWireType;
                value = @intCast(try reader.readVarint());
            },
            else => try reader.skip(field.wire_type),
        }
    }

    return .{ .name = name, .value = value };
}

test "query stats request encode contains pattern" {
    const request = QueryStatsRequest{ .pattern = "outbound>>>" };
    const encoded = try request.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(encoded.len > 0);
}
