# xapi-tool Requirements

## Functional

1. The tool must query Xray local API without invoking `xray api ...`.
2. The first supported RPC must be `xray.app.stats.command.StatsService/QueryStats`.
3. The tool must accept an API endpoint via `--server host:port`.
4. The tool must accept a stats filter via `--pattern`.
5. The tool must emit compact JSON suitable for shell consumption.
6. The initial JSON shape must expose per-outbound traffic counters.
7. The tool must work with local plaintext h2c API endpoints.
8. The codebase must leave room for future handler / routing commands.

## Non-functional

1. Small binary size is required.
2. Startup latency is a primary goal.
3. Cross-compilation for router targets is required.
4. External runtime dependencies should be avoided.
5. The implementation should stay readable and easy to extend.

## Deferred

1. TLS gRPC endpoints.
2. Streaming RPCs.
3. Full HPACK decode support.
4. Generic protobuf support beyond the required Xray API messages.
5. Daemon / persistent connection mode.
