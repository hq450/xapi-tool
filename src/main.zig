const std = @import("std");
const hpack = @import("hpack.zig");
const http2 = @import("http2.zig");
const grpc = @import("grpc.zig");
const stats_proto = @import("stats_proto.zig");
const router_proto = @import("router_proto.zig");
const handler_proto = @import("handler_proto.zig");
const serial_proto = @import("serial_proto.zig");

const version = "0.2.1";

const OutboundCounters = struct {
    tag: []const u8,
    uplink: i64 = 0,
    downlink: i64 = 0,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "stats-query")) {
        try cmdStatsQuery(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, cmd, "routing-list-rule")) {
        try cmdRoutingListRule(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, cmd, "routing-test-route")) {
        try cmdRoutingTestRoute(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, cmd, "routing-add-rule")) {
        try cmdRoutingAddRule(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, cmd, "routing-add-rule-typed")) {
        try cmdRoutingAddRuleTyped(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, cmd, "routing-remove-rule")) {
        try cmdRoutingRemoveRule(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, cmd, "routing-override-balancer-target")) {
        try cmdRoutingOverrideBalancerTarget(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, cmd, "routing-get-balancer-info")) {
        try cmdRoutingGetBalancerInfo(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, cmd, "handler-remove-outbound")) {
        try cmdHandlerRemoveOutbound(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, cmd, "handler-add-outbound-typed")) {
        try cmdHandlerAddOutboundTyped(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, cmd, "version")) {
        const out = std.fs.File.stdout().deprecatedWriter();
        try out.print("{s}\n", .{std.mem.trim(u8, version, "\r\n")});
        return;
    }

    try printUsage();
    return error.InvalidArguments;
}

fn printUsage() !void {
    const out = std.fs.File.stdout().deprecatedWriter();
    try out.writeAll(
        "Usage:\n" ++
        "  xapi-tool stats-query [--server host:port] [--pattern text] [--reset]\n" ++
        "  xapi-tool routing-list-rule [--server host:port]\n" ++
        "  xapi-tool routing-test-route --domain example.com [--inbound-tag tproxy-in] [--server host:port]\n" ++
        "  xapi-tool routing-add-rule --target-tag tag|--balancing-tag tag [--rule-tag tag] [--domain-rule rule ...] [--domain-file path] [--ip-file path] [--network tcp|udp|tcp,udp] [--match-all] [--server host:port]\n" ++
        "  xapi-tool routing-add-rule-typed --type type --value-base64 b64 [--prepend] [--server host:port]\n" ++
        "  xapi-tool routing-remove-rule --rule-tag tag [--server host:port]\n" ++
        "  xapi-tool routing-override-balancer-target --balancer-tag tag --target target [--server host:port]\n" ++
        "  xapi-tool routing-get-balancer-info --tag tag [--server host:port]\n" ++
        "  xapi-tool handler-add-outbound-typed --tag tag --proxy-type type --proxy-value-base64 b64 [--sender-type type --sender-value-base64 b64] [--server host:port]\n" ++
        "  xapi-tool handler-remove-outbound --tag tag [--server host:port]\n" ++
        "  xapi-tool version\n",
    );
}

fn cmdStatsQuery(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var server: []const u8 = "127.0.0.1:10085";
    var pattern: []const u8 = "outbound>>>";
    var reset = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--server")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArguments;
            server = argv[i];
        } else if (std.mem.eql(u8, arg, "--pattern")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArguments;
            pattern = argv[i];
        } else if (std.mem.eql(u8, arg, "--reset")) {
            reset = true;
        } else {
            return error.InvalidArguments;
        }
    }

    const request = stats_proto.QueryStatsRequest{ .pattern = pattern, .reset = reset };
    const req_payload = try request.encode(allocator);
    defer allocator.free(req_payload);

    const grpc_payload = try grpc.frameMessage(allocator, req_payload);
    defer allocator.free(grpc_payload);

    const response = try queryStats(allocator, server, grpc_payload);
    defer response.deinit(allocator);

    try printStatsJson(allocator, response);
}

fn splitServer(server: []const u8) !struct { host: []const u8, port: u16 } {
    const idx = std.mem.lastIndexOfScalar(u8, server, ':') orelse return error.InvalidServer;
    const host = server[0..idx];
    const port = try std.fmt.parseInt(u16, server[idx + 1 ..], 10);
    if (host.len == 0) return error.InvalidServer;
    return .{ .host = host, .port = port };
}

fn performUnaryCall(allocator: std.mem.Allocator, server: []const u8, path: []const u8, grpc_payload: []const u8) ![]u8 {
    const parsed = try splitServer(server);
    var stream = try std.net.tcpConnectToHost(allocator, parsed.host, parsed.port);
    defer stream.close();

    const headers = try hpack.encodeRequestHeaders(allocator, server, path, "xapi-tool/" ++ version);
    defer allocator.free(headers);

    try stream.writeAll(http2.client_preface);
    try http2.writeFrame(stream, .settings, 0, 0, "");
    try http2.writeFrame(stream, .headers, http2.flags.end_headers, 1, headers);
    try http2.writeDataFrames(stream, 1, grpc_payload, true);

    var body = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer body.deinit(allocator);
    var saw_stream_end = false;
    while (!saw_stream_end) {
        const header = try http2.readFrameHeader(stream);
        const payload = try http2.readPayloadAlloc(allocator, stream, header.length);
        defer allocator.free(payload);

        switch (header.frame_type) {
            .settings => {
                if ((header.frame_flags & http2.flags.ack) == 0) {
                    try http2.writeFrame(stream, .settings, http2.flags.ack, 0, "");
                }
            },
            .headers, .continuation => {
                if (header.stream_id == 1 and (header.frame_flags & http2.flags.end_stream) != 0) {
                    saw_stream_end = true;
                }
            },
            .data => {
                if (header.stream_id == 1) {
                    try body.appendSlice(allocator, payload);
                    if ((header.frame_flags & http2.flags.end_stream) != 0) {
                        saw_stream_end = true;
                    }
                }
            },
            .ping => {
                if ((header.frame_flags & http2.flags.ack) == 0) {
                    try http2.writeFrame(stream, .ping, http2.flags.ack, 0, payload);
                }
            },
            .goaway => return error.Http2GoAway,
            .rst_stream => return error.Http2ResetStream,
            else => {},
        }
    }

    if (body.items.len == 0) {
        return allocator.dupe(u8, "");
    }
    return try allocator.dupe(u8, try grpc.extractUnaryMessage(body.items));
}

fn queryStats(allocator: std.mem.Allocator, server: []const u8, grpc_payload: []const u8) !stats_proto.QueryStatsResponse {
    const message = try performUnaryCall(allocator, server, "/xray.app.stats.command.StatsService/QueryStats", grpc_payload);
    defer allocator.free(message);
    return try stats_proto.QueryStatsResponse.decode(allocator, message);
}

fn splitStatName(name: []const u8) ?struct { tag: []const u8, direction: enum { uplink, downlink } } {
    const prefix = "outbound>>>";
    const middle = ">>>traffic>>>";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const tail = name[prefix.len..];
    const mid_idx = std.mem.indexOf(u8, tail, middle) orelse return null;
    const tag = tail[0..mid_idx];
    const dir = tail[mid_idx + middle.len ..];
    if (std.mem.eql(u8, dir, "uplink")) return .{ .tag = tag, .direction = .uplink };
    if (std.mem.eql(u8, dir, "downlink")) return .{ .tag = tag, .direction = .downlink };
    return null;
}

fn printStatsJson(allocator: std.mem.Allocator, response: stats_proto.QueryStatsResponse) !void {
    var counters = try std.ArrayList(OutboundCounters).initCapacity(allocator, 0);
    defer counters.deinit(allocator);
    var total_uplink: i64 = 0;
    var total_downlink: i64 = 0;

    for (response.stats) |stat| {
        const parsed = splitStatName(stat.name) orelse continue;
        var found = false;
        for (counters.items) |*entry| {
            if (std.mem.eql(u8, entry.tag, parsed.tag)) {
                switch (parsed.direction) {
                    .uplink => {
                        total_uplink -= entry.uplink;
                        entry.uplink = stat.value;
                        total_uplink += entry.uplink;
                    },
                    .downlink => {
                        total_downlink -= entry.downlink;
                        entry.downlink = stat.value;
                        total_downlink += entry.downlink;
                    },
                }
                found = true;
                break;
            }
        }
        if (!found) {
            var entry = OutboundCounters{ .tag = parsed.tag };
            switch (parsed.direction) {
                .uplink => {
                    entry.uplink = stat.value;
                    total_uplink += entry.uplink;
                },
                .downlink => {
                    entry.downlink = stat.value;
                    total_downlink += entry.downlink;
                },
            }
            try counters.append(allocator, entry);
        }
    }

    const out = std.fs.File.stdout().deprecatedWriter();
    try out.print(
        "{{\"summary\":{{\"total_uplink\":{},\"total_downlink\":{},\"total_traffic\":{},\"traffic_ready\":1}},\"stats\":{{",
        .{ total_uplink, total_downlink, total_uplink + total_downlink },
    );
    for (counters.items, 0..) |entry, idx| {
        if (idx != 0) try out.writeAll(",");
        try out.print("\"{s}\":{{\"uplink\":{},\"downlink\":{},\"total\":{}}}", .{ entry.tag, entry.uplink, entry.downlink, entry.uplink + entry.downlink });
    }
    try out.writeAll("}}\n");
}

fn getStringArg(argv: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], name) and i + 1 < argv.len) return argv[i + 1];
    }
    return null;
}

fn hasFlag(argv: []const []const u8, name: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

fn getServerArg(argv: []const []const u8) ![]const u8 {
    return getStringArg(argv, "--server") orelse "127.0.0.1:10085";
}

fn decodeBase64Alloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(text);
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    try decoder.decode(out, text);
    return out;
}

fn parseDomainRule(text: []const u8) !router_proto.Domain {
    if (std.mem.startsWith(u8, text, "domain:")) {
        return .{ .domain_type = .domain, .value = text["domain:".len..] };
    }
    if (std.mem.startsWith(u8, text, "full:")) {
        return .{ .domain_type = .full, .value = text["full:".len..] };
    }
    if (std.mem.startsWith(u8, text, "regexp:")) {
        return .{ .domain_type = .regex, .value = text["regexp:".len..] };
    }
    if (std.mem.startsWith(u8, text, "keyword:")) {
        return .{ .domain_type = .plain, .value = text["keyword:".len..] };
    }
    if (std.mem.startsWith(u8, text, "plain:")) {
        return .{ .domain_type = .plain, .value = text["plain:".len..] };
    }
    return .{ .domain_type = .plain, .value = text };
}

fn freeDomains(allocator: std.mem.Allocator, domains: []router_proto.Domain) void {
    for (domains) |domain| allocator.free(domain.value);
    allocator.free(domains);
}

fn parseDomainRuleOwned(allocator: std.mem.Allocator, text: []const u8) !router_proto.Domain {
    var domain = try parseDomainRule(text);
    domain.value = try allocator.dupe(u8, domain.value);
    return domain;
}

fn parseCidrRule(allocator: std.mem.Allocator, text: []const u8) !router_proto.GeoIP {
    const slash_idx = std.mem.lastIndexOfScalar(u8, text, '/') orelse return error.InvalidArguments;
    const ip_text = text[0..slash_idx];
    const prefix = try std.fmt.parseInt(u32, text[slash_idx + 1 ..], 10);
    const addr = try std.net.Address.parseIp(ip_text, 0);

    const ip_bytes = switch (addr.any.family) {
        std.posix.AF.INET => try allocator.dupe(u8, std.mem.asBytes(&addr.in.sa.addr)),
        std.posix.AF.INET6 => try allocator.dupe(u8, std.mem.asBytes(&addr.in6.sa.addr)),
        else => return error.InvalidArguments,
    };
    errdefer allocator.free(ip_bytes);
    const cidrs = try allocator.alloc(router_proto.CIDR, 1);
    cidrs[0] = .{ .ip = ip_bytes, .prefix = prefix };
    return .{ .country_code = "", .cidrs = cidrs };
}

fn parseGeoIpRule(allocator: std.mem.Allocator, text: []const u8) !router_proto.GeoIP {
    if (std.mem.startsWith(u8, text, "geoip:")) {
        return .{ .country_code = try allocator.dupe(u8, text["geoip:".len..]) };
    }
    return try parseCidrRule(allocator, text);
}

fn parseNetworkName(text: []const u8) !router_proto.Network {
    if (std.mem.eql(u8, text, "tcp")) return .tcp;
    if (std.mem.eql(u8, text, "udp")) return .udp;
    return error.InvalidArguments;
}

fn loadDomainRulesFromFile(allocator: std.mem.Allocator, path: []const u8) ![]router_proto.Domain {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 8 * 1024 * 1024);
    defer allocator.free(data);
    var list = try std.ArrayList(router_proto.Domain).initCapacity(allocator, 0);
    errdefer {
        for (list.items) |domain| allocator.free(domain.value);
        list.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try list.append(allocator, try parseDomainRuleOwned(allocator, line));
    }
    return try list.toOwnedSlice(allocator);
}

fn freeGeoIps(allocator: std.mem.Allocator, geoips: []router_proto.GeoIP) void {
    for (geoips) |geoip| {
        if (geoip.country_code.len > 0) allocator.free(geoip.country_code);
        for (geoip.cidrs) |cidr| allocator.free(cidr.ip);
        allocator.free(geoip.cidrs);
    }
    allocator.free(geoips);
}

fn loadGeoIpRulesFromFile(allocator: std.mem.Allocator, path: []const u8) ![]router_proto.GeoIP {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 8 * 1024 * 1024);
    defer allocator.free(data);
    var list = try std.ArrayList(router_proto.GeoIP).initCapacity(allocator, 0);
    errdefer {
        for (list.items) |geoip| {
            if (geoip.country_code.len > 0) allocator.free(geoip.country_code);
            for (geoip.cidrs) |cidr| allocator.free(cidr.ip);
            allocator.free(geoip.cidrs);
        }
        list.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try list.append(allocator, try parseGeoIpRule(allocator, line));
    }
    return try list.toOwnedSlice(allocator);
}

fn cmdRoutingListRule(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const server = try getServerArg(argv);
    const payload = try router_proto.ListRuleRequest.encode(allocator);
    defer allocator.free(payload);
    const grpc_payload = try grpc.frameMessage(allocator, payload);
    defer allocator.free(grpc_payload);
    const message = try performUnaryCall(allocator, server, "/xray.app.router.command.RoutingService/ListRule", grpc_payload);
    defer allocator.free(message);
    const response = try router_proto.ListRuleResponse.decode(allocator, message);
    defer response.deinit(allocator);

    const out = std.fs.File.stdout().deprecatedWriter();
    try out.writeAll("{\"rules\":[");
    for (response.rules, 0..) |rule, idx| {
        if (idx != 0) try out.writeAll(",");
        try out.print("{{\"tag\":\"{s}\",\"rule_tag\":\"{s}\"}}", .{ rule.tag, rule.rule_tag });
    }
    try out.writeAll("]}\n");
}

fn cmdRoutingTestRoute(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const server = try getServerArg(argv);
    const domain = getStringArg(argv, "--domain") orelse return error.InvalidArguments;
    const inbound_tag = getStringArg(argv, "--inbound-tag") orelse "tproxy-in";
    const request = router_proto.TestRouteRequest{
        .context = .{ .inbound_tag = inbound_tag, .network = 2, .target_domain = domain },
    };
    const payload = try request.encode(allocator);
    defer allocator.free(payload);
    const grpc_payload = try grpc.frameMessage(allocator, payload);
    defer allocator.free(grpc_payload);
    const message = try performUnaryCall(allocator, server, "/xray.app.router.command.RoutingService/TestRoute", grpc_payload);
    defer allocator.free(message);
    const result = try router_proto.RoutingContext.decodeResponse(allocator, message);
    defer allocator.free(result.outbound_tag);
    try std.fs.File.stdout().deprecatedWriter().print("{{\"outbound_tag\":\"{s}\"}}\n", .{result.outbound_tag});
}

fn cmdRoutingAddRule(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const server = try getServerArg(argv);
    const target_tag = getStringArg(argv, "--target-tag");
    const balancing_tag = getStringArg(argv, "--balancing-tag");
    if ((target_tag == null and balancing_tag == null) or (target_tag != null and balancing_tag != null)) {
        return error.InvalidArguments;
    }
    if (hasFlag(argv, "--prepend")) return error.InvalidArguments;

    var domains = try std.ArrayList(router_proto.Domain).initCapacity(allocator, 0);
    defer {
        for (domains.items) |domain| allocator.free(domain.value);
        domains.deinit(allocator);
    }
    var geoips = try std.ArrayList(router_proto.GeoIP).initCapacity(allocator, 0);
    defer {
        for (geoips.items) |geoip| {
            if (geoip.country_code.len > 0) allocator.free(geoip.country_code);
            for (geoip.cidrs) |cidr| allocator.free(cidr.ip);
            allocator.free(geoip.cidrs);
        }
        geoips.deinit(allocator);
    }
    var networks = try std.ArrayList(router_proto.Network).initCapacity(allocator, 0);
    defer networks.deinit(allocator);
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--domain-rule")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArguments;
            try domains.append(allocator, try parseDomainRuleOwned(allocator, argv[i]));
        } else if (std.mem.eql(u8, argv[i], "--domain-file")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArguments;
            const loaded = try loadDomainRulesFromFile(allocator, argv[i]);
            try domains.appendSlice(allocator, loaded);
            allocator.free(loaded);
        } else if (std.mem.eql(u8, argv[i], "--ip-file")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArguments;
            const loaded = try loadGeoIpRulesFromFile(allocator, argv[i]);
            try geoips.appendSlice(allocator, loaded);
            allocator.free(loaded);
        } else if (std.mem.eql(u8, argv[i], "--network")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArguments;
            var it = std.mem.splitScalar(u8, argv[i], ',');
            while (it.next()) |part_raw| {
                const part = std.mem.trim(u8, part_raw, " \t\r");
                if (part.len == 0) continue;
                try networks.append(allocator, try parseNetworkName(part));
            }
        }
    }
    if (hasFlag(argv, "--match-all") and networks.items.len == 0) {
        try networks.append(allocator, .tcp);
        try networks.append(allocator, .udp);
    }
    if (domains.items.len == 0 and geoips.items.len == 0 and networks.items.len == 0) return error.InvalidArguments;

    const rule = router_proto.RoutingRule{
        .target_tag = target_tag,
        .balancing_tag = balancing_tag,
        .rule_tag = getStringArg(argv, "--rule-tag"),
        .domains = domains.items,
        .geoips = geoips.items,
        .networks = networks.items,
    };
    const config = router_proto.Config{ .rules = &.{rule} };
    const config_bytes = try config.encode(allocator);
    defer allocator.free(config_bytes);
    const add_req = router_proto.AddRuleRequest{
        .config_value = config_bytes,
        .should_append = !hasFlag(argv, "--prepend"),
    };
    const payload = try add_req.encode(allocator);
    defer allocator.free(payload);
    const grpc_payload = try grpc.frameMessage(allocator, payload);
    defer allocator.free(grpc_payload);
    const message = performUnaryCall(allocator, server, "/xray.app.router.command.RoutingService/AddRule", grpc_payload) catch |err| {
        if (err == error.UnexpectedEof) {
            try std.fs.File.stdout().deprecatedWriter().writeAll("{\"ok\":1}\n");
            return;
        }
        return err;
    };
    defer allocator.free(message);
    try std.fs.File.stdout().deprecatedWriter().writeAll("{\"ok\":1}\n");
}

fn cmdRoutingAddRuleTyped(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const server = try getServerArg(argv);
    _ = getStringArg(argv, "--type") orelse return error.InvalidArguments;
    const value_b64 = getStringArg(argv, "--value-base64") orelse return error.InvalidArguments;
    if (hasFlag(argv, "--prepend")) return error.InvalidArguments;
    const value = try decodeBase64Alloc(allocator, value_b64);
    defer allocator.free(value);
    const request = router_proto.AddRuleRequest{
        .config_value = value,
        .should_append = !hasFlag(argv, "--prepend"),
    };
    const payload = try request.encode(allocator);
    defer allocator.free(payload);
    const grpc_payload = try grpc.frameMessage(allocator, payload);
    defer allocator.free(grpc_payload);
    const message = performUnaryCall(allocator, server, "/xray.app.router.command.RoutingService/AddRule", grpc_payload) catch |err| {
        if (err == error.UnexpectedEof) {
            try std.fs.File.stdout().deprecatedWriter().writeAll("{\"ok\":1}\n");
            return;
        }
        return err;
    };
    defer allocator.free(message);
    try std.fs.File.stdout().deprecatedWriter().writeAll("{\"ok\":1}\n");
}

fn cmdRoutingRemoveRule(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const server = try getServerArg(argv);
    const rule_tag = getStringArg(argv, "--rule-tag") orelse return error.InvalidArguments;
    const request = router_proto.RemoveRuleRequest{ .rule_tag = rule_tag };
    const payload = try request.encode(allocator);
    defer allocator.free(payload);
    const grpc_payload = try grpc.frameMessage(allocator, payload);
    defer allocator.free(grpc_payload);
    const message = performUnaryCall(allocator, server, "/xray.app.router.command.RoutingService/RemoveRule", grpc_payload) catch |err| {
        if (err == error.UnexpectedEof) {
            try std.fs.File.stdout().deprecatedWriter().writeAll("{\"ok\":1}\n");
            return;
        }
        return err;
    };
    defer allocator.free(message);
    try std.fs.File.stdout().deprecatedWriter().writeAll("{\"ok\":1}\n");
}

fn cmdRoutingOverrideBalancerTarget(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const server = try getServerArg(argv);
    const balancer_tag = getStringArg(argv, "--balancer-tag") orelse return error.InvalidArguments;
    const target = getStringArg(argv, "--target") orelse return error.InvalidArguments;
    const request = router_proto.OverrideBalancerTargetRequest{
        .balancer_tag = balancer_tag,
        .target = target,
    };
    const payload = try request.encode(allocator);
    defer allocator.free(payload);
    const grpc_payload = try grpc.frameMessage(allocator, payload);
    defer allocator.free(grpc_payload);
    const message = try performUnaryCall(allocator, server, "/xray.app.router.command.RoutingService/OverrideBalancerTarget", grpc_payload);
    defer allocator.free(message);
    try std.fs.File.stdout().deprecatedWriter().writeAll("{\"ok\":1}\n");
}

fn cmdRoutingGetBalancerInfo(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const server = try getServerArg(argv);
    const tag = getStringArg(argv, "--tag") orelse return error.InvalidArguments;
    const request = router_proto.GetBalancerInfoRequest{ .tag = tag };
    const payload = try request.encode(allocator);
    defer allocator.free(payload);
    const grpc_payload = try grpc.frameMessage(allocator, payload);
    defer allocator.free(grpc_payload);
    const message = try performUnaryCall(allocator, server, "/xray.app.router.command.RoutingService/GetBalancerInfo", grpc_payload);
    defer allocator.free(message);
    const info = try router_proto.BalancerInfo.decode(allocator, message);
    defer info.deinit(allocator);

    const out = std.fs.File.stdout().deprecatedWriter();
    try out.print("{{\"override_target\":\"{s}\",\"principle_targets\":[", .{ info.override_target });
    for (info.principle_targets, 0..) |item, idx| {
        if (idx != 0) try out.writeAll(",");
        try out.print("\"{s}\"", .{item});
    }
    try out.writeAll("]}\n");
}

fn cmdHandlerRemoveOutbound(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const server = try getServerArg(argv);
    const tag = getStringArg(argv, "--tag") orelse return error.InvalidArguments;
    const request = handler_proto.RemoveOutboundRequest{ .tag = tag };
    const payload = try request.encode(allocator);
    defer allocator.free(payload);
    const grpc_payload = try grpc.frameMessage(allocator, payload);
    defer allocator.free(grpc_payload);
    const message = try performUnaryCall(allocator, server, "/xray.app.proxyman.command.HandlerService/RemoveOutbound", grpc_payload);
    defer allocator.free(message);
    try std.fs.File.stdout().deprecatedWriter().writeAll("{\"ok\":1}\n");
}

fn cmdHandlerAddOutboundTyped(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const server = try getServerArg(argv);
    const tag = getStringArg(argv, "--tag") orelse return error.InvalidArguments;
    const proxy_type = getStringArg(argv, "--proxy-type") orelse return error.InvalidArguments;
    const proxy_value_b64 = getStringArg(argv, "--proxy-value-base64") orelse return error.InvalidArguments;
    const proxy_value = try decodeBase64Alloc(allocator, proxy_value_b64);
    defer allocator.free(proxy_value);

    var sender_value: ?[]u8 = null;
    defer if (sender_value) |buf| allocator.free(buf);
    const sender_type = getStringArg(argv, "--sender-type");
    if (getStringArg(argv, "--sender-value-base64")) |sender_b64| {
        sender_value = try decodeBase64Alloc(allocator, sender_b64);
    }

    const request = handler_proto.AddOutboundRequest{
        .tag = tag,
        .proxy_type = proxy_type,
        .proxy_value = proxy_value,
        .sender_type = sender_type,
        .sender_value = sender_value,
    };
    const payload = try request.encode(allocator);
    defer allocator.free(payload);
    const grpc_payload = try grpc.frameMessage(allocator, payload);
    defer allocator.free(grpc_payload);
    const message = try performUnaryCall(allocator, server, "/xray.app.proxyman.command.HandlerService/AddOutbound", grpc_payload);
    defer allocator.free(message);
    try std.fs.File.stdout().deprecatedWriter().writeAll("{\"ok\":1}\n");
}

test "split stat name" {
    const parsed = splitStatName("outbound>>>proxy1>>>traffic>>>uplink") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("proxy1", parsed.tag);
}
