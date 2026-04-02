const std = @import("std");
const router_proto = @import("router_proto.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const rule = router_proto.RoutingRule{
        .target_tag = "proxy2",
        .rule_tag = "xapi_test_rule",
        .domains = &.{.{ .domain_type = .full, .value = "api.ip.sb" }},
    };
    const cfg = router_proto.Config{ .rules = &.{rule} };
    const bytes = try cfg.encode(allocator);
    defer allocator.free(bytes);
    const n = std.base64.standard.Encoder.calcSize(bytes.len);
    const b64 = try allocator.alloc(u8, n);
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, bytes);
    try std.fs.File.stdout().writeAll(b64);
    try std.fs.File.stdout().writeAll("\n");
}
