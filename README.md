# xapi-tool

`xapi-tool` 是一个使用 Zig 编写的轻量级 Xray API 命令行客户端。

它的目标不是做一个“功能完整的通用 gRPC 工具”，而是针对路由器场景，把 `xray api ...` 这类一次性命令的启动成本尽量压低，给 `fancyss` 这类壳脚本系统提供一个更快、更小、更稳定的本地控制面。

当前版本：`0.2.1`

## 1. 为什么要做这个工具

在 `fancyss` 里，Xray API 的典型调用方式原本是：

```bash
xray api statsquery --server=127.0.0.1:10085
```

这条命令本身没有复杂逻辑，但在路由器上会有明显的单次启动成本，尤其是在以下热路径里：

- 流量统计轮询
- 节点分流热更新
- 运行时规则调整
- 动态 outbound / balancer 操作

`xapi-tool` 的核心思路是：

- 不再启动 `xray api ...` 子命令
- 直接用 TCP 连接本地 Xray API
- 直接说 HTTP/2 + gRPC
- 只实现当前确实需要的最小协议子集

在 GS7 上的早期测试结果：

- `xray api statsquery`：约 `1072 ms`
- `xapi-tool stats-query`：约 `4 ms`
- `fancyss` 中 `ss_shunt_stats.sh` 切换后总耗时：约 `72 ms`

这就是这个项目存在的原因。

## 2. 项目定位

`xapi-tool` 当前面向的是“本机到本机”的 Xray API 控制场景，典型运行环境是：

- 路由器
- 本地 Linux 主机
- 明文本地 API 监听，例如 `127.0.0.1:10085`

它不是面向以下场景设计的：

- 远端 TLS gRPC API
- 流式 RPC
- 完整 HPACK 解码
- 泛化 protobuf 运行时
- 通用 gRPC 调试工具

也就是说，它是一个“为实际集成服务的窄而深工具”，不是一个大而全框架。

## 3. 当前能力

当前已实现的命令有：

```bash
xapi-tool stats-query
xapi-tool routing-list-rule
xapi-tool routing-test-route
xapi-tool routing-add-rule
xapi-tool routing-add-rule-typed
xapi-tool routing-remove-rule
xapi-tool routing-override-balancer-target
xapi-tool routing-get-balancer-info
xapi-tool handler-add-outbound-typed
xapi-tool handler-remove-outbound
xapi-tool version
```

对应的服务面主要有两类：

- `StatsService`
- `RoutingService`
- `HandlerService`

## 4. 设计边界与限制

当前实现明确接受以下限制：

- 只支持 unary RPC
- 只支持明文 `h2c` over TCP
- 不支持 TLS
- 不做通用 HPACK 解码，只做请求侧最小编码
- 不做完整 protobuf 抽象，只覆盖当前用到的 Xray API 消息
- `typed` 类命令假定调用方知道自己在传什么 protobuf 二进制内容

这些限制是有意的。对 `fancyss` 和路由器场景来说，低体积、低延迟、低依赖，比“通用能力”更重要。

## 5. 快速开始

### 5.1 编译

需要 Zig。

直接构建：

```bash
zig build
```

构建后可执行文件位于：

```bash
./zig-out/bin/xapi-tool
```

### 5.2 运行示例

查询 Xray outbound 流量统计：

```bash
./zig-out/bin/xapi-tool stats-query --server 127.0.0.1:10085 --pattern 'outbound>>>'
```

预期输出类似：

```json
{"summary":{"total_uplink":1,"total_downlink":2,"total_traffic":3,"traffic_ready":1},"stats":{"proxy1":{"uplink":1,"downlink":2,"total":3}}}
```

查看版本：

```bash
./zig-out/bin/xapi-tool version
```

## 6. 命令详解

### 6.1 `stats-query`

用途：

- 查询 Xray `StatsService.QueryStats`
- 输出紧凑 JSON，适合 shell 直接消费

命令格式：

```bash
xapi-tool stats-query [--server host:port] [--pattern text] [--reset]
```

参数说明：

- `--server`
  - API 地址，默认 `127.0.0.1:10085`
- `--pattern`
  - 统计过滤模式，默认 `outbound>>>`
- `--reset`
  - 查询后重置对应统计

示例：

```bash
xapi-tool stats-query --pattern 'outbound>>>'
xapi-tool stats-query --pattern 'user>>>' --reset
```

输出特点：

- `summary` 里给出总上行、总下行、总流量
- `stats` 里按 outbound tag 聚合
- 当前主要围绕 `outbound>>>...>>>traffic>>>uplink/downlink` 这类统计名设计

### 6.2 `routing-list-rule`

用途：

- 列出当前 routing 规则的标签信息

命令格式：

```bash
xapi-tool routing-list-rule [--server host:port]
```

示例：

```bash
xapi-tool routing-list-rule
```

输出示例：

```json
{"rules":[{"tag":"field","rule_tag":"my-rule"}]}
```

说明：

- 当前输出是轻量 JSON，不追求完整展开规则细节
- 主要用于运行时排查和管理面快速确认

### 6.3 `routing-test-route`

用途：

- 调用 Xray 路由测试接口，验证某个域名会命中哪个 outbound

命令格式：

```bash
xapi-tool routing-test-route --domain example.com [--inbound-tag tproxy-in] [--server host:port]
```

参数说明：

- `--domain`
  - 必填，要测试的目标域名
- `--inbound-tag`
  - 可选，默认 `tproxy-in`

示例：

```bash
xapi-tool routing-test-route --domain openai.com
```

输出示例：

```json
{"outbound_tag":"proxy3"}
```

### 6.4 `routing-add-rule`

用途：

- 用结构化参数构造 routing rule
- 适合 shell 脚本动态加规则

命令格式：

```bash
xapi-tool routing-add-rule \
  --target-tag tag | --balancing-tag tag \
  [--rule-tag tag] \
  [--domain-rule rule ...] \
  [--domain-file path] \
  [--ip-file path] \
  [--network tcp|udp|tcp,udp] \
  [--match-all] \
  [--prepend] \
  [--server host:port]
```

参数说明：

- `--target-tag`
  - 目标 outbound tag
- `--balancing-tag`
  - 目标 balancer tag
- `--rule-tag`
  - 给规则一个稳定 tag，便于后续删除
- `--domain-rule`
  - 直接追加一条域名规则，可重复传多次
- `--domain-file`
  - 从文件加载域名规则
- `--ip-file`
  - 从文件加载 IP / GEOIP 规则
- `--network`
  - 规则适用网络，可传 `tcp`、`udp` 或 `tcp,udp`
- `--match-all`
  - 当未提供网络时，快速构造 `tcp+udp` 全量网络规则
- `--prepend`
  - 头插规则；默认是尾插

域名规则支持格式：

- `domain:example.com`
- `full:api.example.com`
- `regexp:^example`
- `keyword:google`
- `plain:text`

如果不带前缀，默认按 `plain` 处理。

`--ip-file` 支持的每行格式：

- `geoip:cn`
- `1.2.3.0/24`
- `2001:db8::/32`

示例 1：从文件增加一条分流规则

```bash
xapi-tool routing-add-rule \
  --rule-tag fancyss-openai \
  --target-tag proxy3 \
  --domain-file /tmp/openai.domains \
  --ip-file /tmp/openai.ips \
  --prepend
```

示例 2：增加一条按网络兜底的规则

```bash
xapi-tool routing-add-rule \
  --rule-tag fancyss-catchall \
  --target-tag proxy1 \
  --match-all
```

### 6.5 `routing-add-rule-typed`

用途：

- 直接发送已编码好的 routing config protobuf 二进制
- 适合更底层、更强控制的集成

命令格式：

```bash
xapi-tool routing-add-rule-typed --type type --value-base64 b64 [--prepend] [--server host:port]
```

说明：

- `--type` 当前主要作为调用方显式声明和参数校验使用
- `--value-base64` 是 protobuf 二进制内容的 base64
- 该命令面向“调用方已经准备好完整 payload”的高级场景

### 6.6 `routing-remove-rule`

用途：

- 按 `rule_tag` 删除 routing 规则

命令格式：

```bash
xapi-tool routing-remove-rule --rule-tag tag [--server host:port]
```

示例：

```bash
xapi-tool routing-remove-rule --rule-tag fancyss-openai
```

### 6.7 `routing-override-balancer-target`

用途：

- 临时重写 balancer 的目标节点

命令格式：

```bash
xapi-tool routing-override-balancer-target --balancer-tag tag --target target [--server host:port]
```

示例：

```bash
xapi-tool routing-override-balancer-target --balancer-tag auto-balancer --target proxy2
```

### 6.8 `routing-get-balancer-info`

用途：

- 查询 balancer 当前覆盖目标和原则目标列表

命令格式：

```bash
xapi-tool routing-get-balancer-info --tag tag [--server host:port]
```

输出示例：

```json
{"override_target":"proxy2","principle_targets":["proxy1","proxy2","proxy3"]}
```

### 6.9 `handler-remove-outbound`

用途：

- 删除指定 outbound

命令格式：

```bash
xapi-tool handler-remove-outbound --tag tag [--server host:port]
```

### 6.10 `handler-add-outbound-typed`

用途：

- 直接向 Xray 动态注册 outbound
- 适合 shell 或上层程序传入已编码好的 outbound / sender 设置

命令格式：

```bash
xapi-tool handler-add-outbound-typed \
  --tag tag \
  --proxy-type type \
  --proxy-value-base64 b64 \
  [--sender-type type --sender-value-base64 b64] \
  [--server host:port]
```

参数说明：

- `--tag`
  - 新 outbound 的 tag
- `--proxy-type`
  - outbound proxy 的类型名
- `--proxy-value-base64`
  - protobuf 二进制的 base64
- `--sender-type`
  - sender settings 类型名，可选
- `--sender-value-base64`
  - sender settings protobuf 二进制的 base64，可选

这个命令同样属于高级接口，主要用于程序集成，而不是手工直接写。

## 7. 构建与测试

### 7.1 本地构建

```bash
zig build
```

### 7.2 直接运行

```bash
zig build run -- stats-query --server 127.0.0.1:10085 --pattern 'outbound>>>'
```

### 7.3 测试

```bash
zig build test
```

当前测试覆盖很轻，主要还是依赖：

- 本地编译通过
- 对 live Xray API 的实际调用验证
- 集成到 `fancyss` 后的端到端联调

## 8. 发布构建

发布脚本：

```bash
bash ./scripts/build-release.sh
```

默认目标：

- `x86_64`
- `armv5te`
- `armv7a`
- `armv7hf`
- `aarch64`

默认行为：

- 使用 `ReleaseSmall`
- 开启 `-fstrip`
- 单线程
- 输出到 `dist/`
- 默认使用 UPX 压缩

关闭 UPX：

```bash
bash ./scripts/build-release.sh --no-upx
```

只构建指定目标：

```bash
bash ./scripts/build-release.sh armv7a aarch64
```

### 8.1 Zig 与 UPX

发布脚本会：

- 自动寻找本机可用的 Zig
- 优先使用系统 `upx`
- 如果本机 `upx` 太旧，会尝试拉取本地缓存版到 `.upx-cache/`

如果你需要手动指定：

```bash
ZIG=/path/to/zig bash ./scripts/build-release.sh
```

## 9. 目录结构

```text
xapi-tool/
├── build.zig
├── VERSION
├── README.md
├── DESIGN.md
├── REQUIREMENTS.md
├── proto/
│   └── xray/...                # vendored Xray proto references
├── scripts/
│   ├── build-release.sh
│   └── ensure_local_upx.sh
└── src/
    ├── main.zig                # CLI 入口和命令调度
    ├── pb.zig                  # 最小 protobuf 读写
    ├── http2.zig               # 最小 HTTP/2 frame 处理
    ├── hpack.zig               # 最小请求头 HPACK 编码
    ├── grpc.zig                # gRPC framing
    ├── stats_proto.zig         # StatsService 消息
    ├── router_proto.zig        # RoutingService 消息
    ├── handler_proto.zig       # HandlerService 消息
    ├── core_proto.zig
    ├── serial_proto.zig
    └── dump_rule.zig
```

## 10. 和 fancyss 的关系

`xapi-tool` 最初就是为 `fancyss` 写的，主要服务：

- `ss_shunt_stats.sh`
- 节点分流热更新
- 运行时 routing / balancer 调整

但它本身并不依赖 `fancyss` 运行，可以作为独立项目单独构建和发布。

## 11. 适合继续扩展的方向

如果继续往前推进，优先级大致是：

1. 补充更多稳定的 `RoutingService` / `HandlerService` 控制命令
2. 继续完善 `typed` 接口对应的文档和示例
3. 评估是否需要更细的 exit code
4. 仅在必要时再考虑连接复用或 daemon 模式

当前不建议优先做的方向：

- 一上来做 TLS
- 一上来做泛化 gRPC 框架
- 一上来把 protobuf 抽象成完整 runtime

这些都会明显抬高体积和复杂度，和项目目标不一致。

## 12. License

当前独立仓库建议沿用 `GPL-3.0`。
