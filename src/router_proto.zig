const std = @import("std");
const pb = @import("pb.zig");
const serial_proto = @import("serial_proto.zig");

pub const DomainType = enum(u64) {
    plain = 0,
    regex = 1,
    domain = 2,
    full = 3,
};

pub const Network = enum(u64) {
    tcp = 2,
    udp = 3,
};

pub const Domain = struct {
    domain_type: DomainType,
    value: []const u8,

    pub fn encode(self: Domain, allocator: std.mem.Allocator) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer out.deinit(allocator);
        var writer = pb.Writer.init(allocator, &out);
        try writer.writeTag(1, .varint);
        try writer.writeVarint(@intFromEnum(self.domain_type));
        try writer.writeString(2, self.value);
        return out.toOwnedSlice(allocator);
    }
};

pub const CIDR = struct {
    ip: []const u8,
    prefix: u32,

    pub fn encode(self: CIDR, allocator: std.mem.Allocator) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer out.deinit(allocator);
        var writer = pb.Writer.init(allocator, &out);
        try writer.writeMessage(1, self.ip);
        try writer.writeTag(2, .varint);
        try writer.writeVarint(self.prefix);
        return out.toOwnedSlice(allocator);
    }
};

pub const GeoIP = struct {
    country_code: []const u8 = "",
    cidrs: []const CIDR = &.{},
    reverse_match: bool = false,

    pub fn encode(self: GeoIP, allocator: std.mem.Allocator) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer out.deinit(allocator);
        var writer = pb.Writer.init(allocator, &out);
        if (self.country_code.len > 0) try writer.writeString(1, self.country_code);
        for (self.cidrs) |cidr| {
            const encoded = try cidr.encode(allocator);
            defer allocator.free(encoded);
            try writer.writeMessage(2, encoded);
        }
        if (self.reverse_match) try writer.writeBool(3, true);
        return out.toOwnedSlice(allocator);
    }
};

pub const RoutingRule = struct {
    target_tag: ?[]const u8 = null,
    balancing_tag: ?[]const u8 = null,
    rule_tag: ?[]const u8 = null,
    domains: []const Domain = &.{},
    geoips: []const GeoIP = &.{},
    networks: []const Network = &.{},

    pub fn encode(self: RoutingRule, allocator: std.mem.Allocator) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer out.deinit(allocator);
        var writer = pb.Writer.init(allocator, &out);

        if (self.target_tag) |tag| try writer.writeString(1, tag);
        if (self.balancing_tag) |tag| try writer.writeString(12, tag);
        if (self.rule_tag) |tag| try writer.writeString(19, tag);

        for (self.domains) |domain| {
            const encoded = try domain.encode(allocator);
            defer allocator.free(encoded);
            try writer.writeMessage(2, encoded);
        }
        for (self.geoips) |geoip| {
            const encoded = try geoip.encode(allocator);
            defer allocator.free(encoded);
            try writer.writeMessage(10, encoded);
        }
        for (self.networks) |network| {
            try writer.writeTag(13, .varint);
            try writer.writeVarint(@intFromEnum(network));
        }

        return out.toOwnedSlice(allocator);
    }
};

pub const Config = struct {
    rules: []const RoutingRule = &.{},

    pub fn encode(self: Config, allocator: std.mem.Allocator) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer out.deinit(allocator);
        var writer = pb.Writer.init(allocator, &out);
        for (self.rules) |rule| {
            const encoded = try rule.encode(allocator);
            defer allocator.free(encoded);
            try writer.writeMessage(2, encoded);
        }
        return out.toOwnedSlice(allocator);
    }
};

pub const ListRuleRequest = struct {
    pub fn encode(allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, "");
    }
};

pub const RemoveRuleRequest = struct {
    rule_tag: []const u8,

    pub fn encode(self: RemoveRuleRequest, allocator: std.mem.Allocator) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer out.deinit(allocator);
        var writer = pb.Writer.init(allocator, &out);
        try writer.writeString(1, self.rule_tag);
        return out.toOwnedSlice(allocator);
    }
};

pub const AddRuleRequest = struct {
    config_value: []const u8,
    should_append: bool = true,

    pub fn encode(self: AddRuleRequest, allocator: std.mem.Allocator) ![]u8 {
        const typed_message = serial_proto.TypedMessage{
            .type_name = "xray.app.router.Config",
            .value = self.config_value,
        };
        const typed = try typed_message.encode(allocator);
        defer allocator.free(typed);

        var out = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer out.deinit(allocator);
        var writer = pb.Writer.init(allocator, &out);
        try writer.writeMessage(1, typed);
        if (self.should_append) try writer.writeBool(2, true);
        return out.toOwnedSlice(allocator);
    }
};

pub const OverrideBalancerTargetRequest = struct {
    balancer_tag: []const u8,
    target: []const u8,

    pub fn encode(self: OverrideBalancerTargetRequest, allocator: std.mem.Allocator) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer out.deinit(allocator);
        var writer = pb.Writer.init(allocator, &out);
        try writer.writeString(1, self.balancer_tag);
        try writer.writeString(2, self.target);
        return out.toOwnedSlice(allocator);
    }
};

pub const GetBalancerInfoRequest = struct {
    tag: []const u8,

    pub fn encode(self: GetBalancerInfoRequest, allocator: std.mem.Allocator) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer out.deinit(allocator);
        var writer = pb.Writer.init(allocator, &out);
        try writer.writeString(1, self.tag);
        return out.toOwnedSlice(allocator);
    }
};

pub const RoutingContext = struct {
    inbound_tag: []const u8 = "",
    network: u64 = 2,
    target_domain: []const u8 = "",
    outbound_tag: []u8 = &[_]u8{},

    pub fn encodeRequest(self: RoutingContext, allocator: std.mem.Allocator) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer out.deinit(allocator);
        var writer = pb.Writer.init(allocator, &out);
        if (self.inbound_tag.len > 0) try writer.writeString(1, self.inbound_tag);
        try writer.writeTag(2, .varint);
        try writer.writeVarint(self.network);
        if (self.target_domain.len > 0) try writer.writeString(7, self.target_domain);
        return out.toOwnedSlice(allocator);
    }

    pub fn decodeResponse(allocator: std.mem.Allocator, data: []const u8) !RoutingContext {
        var reader = pb.Reader.init(data);
        var outbound_tag = try allocator.dupe(u8, "");
        errdefer allocator.free(outbound_tag);
        while (!reader.eof()) {
            const field = try reader.readField();
            switch (field.number) {
                12 => {
                    if (field.wire_type != .length_delimited) return error.InvalidWireType;
                    allocator.free(outbound_tag);
                    outbound_tag = try allocator.dupe(u8, try reader.readBytes());
                },
                else => try reader.skip(field.wire_type),
            }
        }
        return .{ .outbound_tag = outbound_tag };
    }
};

pub const TestRouteRequest = struct {
    context: RoutingContext,

    pub fn encode(self: TestRouteRequest, allocator: std.mem.Allocator) ![]u8 {
        const ctx = try self.context.encodeRequest(allocator);
        defer allocator.free(ctx);
        var out = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer out.deinit(allocator);
        var writer = pb.Writer.init(allocator, &out);
        try writer.writeMessage(1, ctx);
        return out.toOwnedSlice(allocator);
    }
};

pub const ListRuleItem = struct {
    tag: []u8,
    rule_tag: []u8,
};

pub const ListRuleResponse = struct {
    rules: []ListRuleItem,

    pub fn deinit(self: ListRuleResponse, allocator: std.mem.Allocator) void {
        for (self.rules) |item| {
            allocator.free(item.tag);
            allocator.free(item.rule_tag);
        }
        allocator.free(self.rules);
    }

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) !ListRuleResponse {
        var reader = pb.Reader.init(data);
        var rules = try std.ArrayList(ListRuleItem).initCapacity(allocator, 0);
        errdefer {
            for (rules.items) |item| {
                allocator.free(item.tag);
                allocator.free(item.rule_tag);
            }
            rules.deinit(allocator);
        }

        while (!reader.eof()) {
            const field = try reader.readField();
            switch (field.number) {
                1 => {
                    if (field.wire_type != .length_delimited) return error.InvalidWireType;
                    const bytes = try reader.readBytes();
                    try rules.append(allocator, try decodeListRuleItem(allocator, bytes));
                },
                else => try reader.skip(field.wire_type),
            }
        }

        return .{ .rules = try rules.toOwnedSlice(allocator) };
    }
};

pub const BalancerInfo = struct {
    override_target: []u8,
    principle_targets: [][]u8,

    pub fn deinit(self: BalancerInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.override_target);
        for (self.principle_targets) |tag| allocator.free(tag);
        allocator.free(self.principle_targets);
    }

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) !BalancerInfo {
        var reader = pb.Reader.init(data);
        var override_target = try allocator.dupe(u8, "");
        errdefer allocator.free(override_target);
        var principle_targets = try std.ArrayList([]u8).initCapacity(allocator, 0);
        errdefer {
            for (principle_targets.items) |tag| allocator.free(tag);
            principle_targets.deinit(allocator);
        }

        while (!reader.eof()) {
            const field = try reader.readField();
            switch (field.number) {
                1 => {
                    if (field.wire_type != .length_delimited) return error.InvalidWireType;
                    const bytes = try reader.readBytes();
                    try decodeBalancerMsg(allocator, bytes, &override_target, &principle_targets);
                },
                else => try reader.skip(field.wire_type),
            }
        }

        return .{ .override_target = override_target, .principle_targets = try principle_targets.toOwnedSlice(allocator) };
    }
};

fn decodeListRuleItem(allocator: std.mem.Allocator, data: []const u8) !ListRuleItem {
    var reader = pb.Reader.init(data);
    var tag = try allocator.dupe(u8, "");
    errdefer allocator.free(tag);
    var rule_tag = try allocator.dupe(u8, "");
    errdefer allocator.free(rule_tag);

    while (!reader.eof()) {
        const field = try reader.readField();
        switch (field.number) {
            1 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                allocator.free(tag);
                tag = try allocator.dupe(u8, try reader.readBytes());
            },
            2 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                allocator.free(rule_tag);
                rule_tag = try allocator.dupe(u8, try reader.readBytes());
            },
            else => try reader.skip(field.wire_type),
        }
    }

    return .{ .tag = tag, .rule_tag = rule_tag };
}

fn decodeBalancerMsg(allocator: std.mem.Allocator, data: []const u8, override_target: *[]u8, principle_targets: *std.ArrayList([]u8)) !void {
    var reader = pb.Reader.init(data);
    while (!reader.eof()) {
        const field = try reader.readField();
        switch (field.number) {
            5 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                const bytes = try reader.readBytes();
                try decodeOverrideInfo(allocator, bytes, override_target);
            },
            6 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                const bytes = try reader.readBytes();
                try decodePrincipleTargetInfo(allocator, bytes, principle_targets);
            },
            else => try reader.skip(field.wire_type),
        }
    }
}

fn decodeOverrideInfo(allocator: std.mem.Allocator, data: []const u8, override_target: *[]u8) !void {
    var reader = pb.Reader.init(data);
    while (!reader.eof()) {
        const field = try reader.readField();
        switch (field.number) {
            2 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                allocator.free(override_target.*);
                override_target.* = try allocator.dupe(u8, try reader.readBytes());
            },
            else => try reader.skip(field.wire_type),
        }
    }
}

fn decodePrincipleTargetInfo(allocator: std.mem.Allocator, data: []const u8, principle_targets: *std.ArrayList([]u8)) !void {
    var reader = pb.Reader.init(data);
    while (!reader.eof()) {
        const field = try reader.readField();
        switch (field.number) {
            1 => {
                if (field.wire_type != .length_delimited) return error.InvalidWireType;
                try principle_targets.append(allocator, try allocator.dupe(u8, try reader.readBytes()));
            },
            else => try reader.skip(field.wire_type),
        }
    }
}
