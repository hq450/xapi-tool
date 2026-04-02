# xapi-tool Design

## 1. Purpose

`xapi-tool` exists to remove the per-call startup cost of `xray api ...` from fancyss.

Current measured bottleneck on GS7 before `xapi-tool`:
- `ss_shunt_stats.sh` total: about 1100 ms
- `xray api statsquery`: about 1050 ms
- everything else: tens of ms

Current measured result on GS7 after `xapi-tool` replacement in `ss_shunt_stats.sh`:
- `xapi-tool stats-query`: about 4 ms
- `ss_shunt_stats.sh` total: about 72 ms

So the target is clear: replace the client-side API command first.

## 2. Scope

Phase 1:
- unary `StatsService.QueryStats`
- compact JSON output for fancyss shell consumption
- plain h2c TCP transport only

Phase 2:
- `StatsService.GetStats`
- evaluate daemon mode / connection reuse only if one-shot latency is still a problem
- machine-friendly exit codes

Phase 3:
- `HandlerService` helpers
  - remove outbound
- `RoutingService` helpers
  - remove rule
  - list rule
  - override balancer target
  - query balancer info

## 3. Constraints

- small binary size matters
- low startup latency matters more than feature richness
- avoid heavy runtime dependencies
- router environment is local, simple, mostly IPv4, often plaintext API
- implementation should tolerate future fancyss hot-reload needs

## 4. Transport choice

Xray API is gRPC over HTTP/2.

For router use, the smallest viable approach is:
- direct TCP socket
- HTTP/2 client preface
- small subset of frame handling
- tiny HPACK encoder for request headers only
- protobuf encode/decode for the specific messages we use

Why not a full third-party stack:
- larger dependency surface
- worse binary size control
- harder cross-build / router packaging story

## 5. MVP behavior

Command:
- `stats-query --server 127.0.0.1:10085 --pattern 'outbound>>>'`

Behavior:
- connect to Xray API by TCP
- issue one gRPC unary request to `xray.app.stats.command.StatsService/QueryStats`
- parse protobuf response
- emit compact JSON with per-tag traffic counters

Output shape:

```json
{"summary":{"total_uplink":123,"total_downlink":456,"total_traffic":579,"traffic_ready":1},"stats":{"proxy1":{"uplink":123,"downlink":456,"total":579}}}
```

## 6. Success criteria

Initial local target:
- working query against a live Xray API
- output compatible with fancyss shell integration

Performance target:
- meaningfully below current `xray api statsquery`
- first milestone: under 300 ms one-shot on host
- later milestone: under 100 ms with daemon / reuse mode

## 7. File layout

- `src/main.zig` CLI entry
- `src/pb.zig` tiny protobuf reader/writer
- `src/hpack.zig` minimal request-side HPACK encoder
- `src/http2.zig` small HTTP/2 frame helpers
- `src/grpc.zig` gRPC wire framing helpers
- `src/stats_proto.zig` StatsService message encode/decode
- `proto/` vendored official reference files

## 8. Risks

Main risk is not protobuf; it is HTTP/2 + gRPC correctness.

Known limits of current implementation:
- unary calls only
- no TLS
- no generic header compression decoder
- minimal frame handling only
- add-outbound / add-rule are not implemented yet because they require larger config proto coverage

These are acceptable for local router-side API control.
