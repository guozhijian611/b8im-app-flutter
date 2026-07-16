# b8im-app-flutter

b8im Flutter App 仓库，用于按企业码、租户信息和配置中心 JSON 动态渲染移动端 IM 体验。

## 当前状态

当前已建立 Flutter 3.44.6 / Dart 3.12.2 的 Android 与 iOS 工程，首个可运行基座包含：

- 企业码与域名两种 `/saimulti/appInfo?client_family=app` 发现客户端。
- 默认测试环境发现入口 `https://api.idev.love`。
- schema v2 线路解析、HTTPS/WSS 强校验、有效期与 deployment 校验。
- Ed25519 + 规范化 JSON 的线路签名验证；受信公钥必须由构建环境注入，不能从未验签响应动态信任。
- 持久化随机设备 ID 和 W3C `traceparent` 的 HTTP/IM envelope 传播。
- 固定模块白名单注册器；只有 App 已内置、后端 capability/permission 齐全且租户授权可用的模块才会渲染。
- 单元、组件和线上发现 smoke 脚本。

本阶段尚未实现登录、IM 会话、推送和具体商业模块页面；这些能力将在该基座上逐个以 Flutter package 接入，不能把注册器本身描述成模块已完成。

## 本机开发

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter build ios --simulator --no-codesign
```

Android applicationId 与 iOS bundle identifier 均为 `love.idev.b8im`。正式 Android/iOS 商店签名不进入仓库，由发布环境注入。

运行 App 时，线路签名公钥作为非秘密信任根由构建参数传入：

```bash
flutter run \
  --dart-define=B8IM_DISCOVERY_BASE_URL=https://api.idev.love \
  --dart-define=B8IM_ENTERPRISE_CODE=<测试企业码> \
  --dart-define=B8IM_ROUTING_PUBLIC_KEYS='<kid 到 Ed25519 公钥的 JSON>'
```

线上发现 smoke 必须使用测试环境真实地址和真实发布快照：

```bash
B8IM_DISCOVERY_BASE_URL=https://api.idev.love \
B8IM_ENTERPRISE_CODE=<测试企业码> \
B8IM_ROUTING_PUBLIC_KEYS='<kid 到 Ed25519 公钥的 JSON>' \
dart run tool/online_discovery_smoke.dart
```

脚本会验证签名，并强制断言 API 为 `api.idev.love`、IM 为 `ws.idev.love`；不接受 localhost 或 mock 作为线上联调结果。

## App 模块接入

模块 package 通过 path/private pub 依赖接入，并向 `ClientModuleRegistry` 提供 `ClientModuleRegistration`。注册对象必须声明：

- `moduleKey`
- App 端 capability
- App 端 permission
- 固定 Flutter builder

服务端下发未知模块、缺 capability/permission、租户未授权或 App 未内置时均不渲染。前端隐藏不替代后端、IM 的授权校验。

## SDK 与 adapter 边界

后续真实 App 工程使用 [`flutterrific_opentelemetry` 0.4.0](https://pub.dev/packages/flutterrific_opentelemetry) 作为 SDK 基线。首次引入时在 `pubspec.yaml` 锁定精确版本 `0.4.0`，提交 `pubspec.lock`，业务代码不得直接调用第三方 SDK。

自有 adapter 将是唯一入口，建议放在 `lib/observability/`，对业务层只暴露以下能力：

- `initialize(config)`：注入 `service.name=b8im-app-flutter`、版本、环境、采样率、OTLP endpoint 和上报凭据提供器。
- `startClientSpan(operation, parentContext, safeAttributes)`：创建有限时长的 CLIENT/PRODUCER/CONSUMER span，不建立跨整个 App 会话的无限长 span。
- `injectHttp(headers, spanContext)` 与 `extractHttp(headers)`：仅处理 W3C `traceparent`/可选 `tracestate`。
- `injectImEnvelope(packet, spanContext)` 与 `extractImEnvelope(packet)`：把 Trace Context 放在 WebSocket/IM envelope 顶层，不放入消息 `content`。
- `recordError(span, errorInfo)`：设置 `SpanStatusCode.error` 并记录脱敏 error/exception event。
- `forceFlush(timeout)`：登出、App 转后台或正常关闭时做有上限的批量刷新；超时不阻断业务或退出。
- `shutdown(timeout)`：有界释放 processor/exporter，多次调用必须幂等。

adapter 负责把 SDK 版本变化限制在 `observability` 内部；HTTP 客户端、IM 运行时、页面和商业模块不得导入 `flutterrific_opentelemetry` 或 `dartastic_opentelemetry` 类型。

## 配置契约

adapter 配置至少包含：

```text
enabled
serviceName
serviceVersion
environment
otlpEndpoint
otlpProtocol
samplingRatio
exportTimeout
flushInterval
maxQueueSize
maxExportBatchSize
credentialProvider
```

约束：

- Android/iOS 使用 OTLP/gRPC；如未来同一工程构建 Flutter Web，使用 OTLP/HTTP Protobuf。
- App 绝不直连 Docker 内网 Jaeger，也不将长期 ingest Token 写入源码、`--dart-define`、安装包或公开构建日志。
- 当前没有受鉴权的公网 ingest gateway，所以真实 App 初版必须允许 `enabled=false`，只向 API/IM 传播 W3C 上下文，由受信服务端上报。
- 开启客户端 OTLP 前，ingest gateway 必须支持 TLS、可撤销短期凭据、按部署/机构限流、请求体限制、signal allowlist 和采样上限。
- Exporter 采用有界 BatchSpanProcessor；队列满、超时或端点故障时丢弃 telemetry 并记录本地计数，不得阻断 HTTP、IM 发送、消息落库或 UI。

## 传播契约

- HTTP 使用 Header `traceparent` 和可选 `tracestate`。
- WebSocket 握手不依赖自定义 Header；`AUTH`、`SEND`、`SYNC`、撤回、编辑等业务 envelope 顶层携带同名字段。
- 每一跳生成新 `span_id`；合法父上下文只继续 `trace_id` 和 trace flags。
- 无效、超长、全零或不支持的 Trace Context 开启新 Trace，不中断业务。
- 不传播 baggage，不把 `organization`、用户身份或权限结果当作客户端可信数据；服务端必须在鉴权后重新写入权威属性。
- `trace_id` 不代替 `message_id`、`client_msg_id`、幂等键、outbox ID 或 `organization`。

## 属性和 ERROR allowlist

允许的客户端属性仅包含：

```text
service.name
service.version
deployment.environment
client.family = app
os.type
app.build
operation
http.request.method
http.route
http.response.status_code
error.code
error.type
retry.count
client_msg_id / message_id（仅故障关联必需时）
```

禁止采集：

```text
Authorization / Cookie / 密码 / access token / refresh token / IM token
消息正文、引用正文、合并转发正文
完整请求/响应 body、完整 Header、带值查询参数
带参 SQL、附件签名 URL、本地文件路径和文件名
手机号、邮箱、账号、昵称、任意表单输入
```

未处理异常和关键业务失败必须：

1. 将 Span 设为 `ERROR`。
2. 写入脱敏 error/exception event。
3. 至少保留稳定 `error.code`、`error.type`、service、operation、重试次数和必要关联 ID。
4. 对异常 message/stack 先过滤 Token、URL query、本地路径和业务数据；无法证明安全时只保留类型和稳定错误码。

## 未来验证门槛

真实 Flutter 工程建立后，至少完成：

1. `flutter pub get`、`flutter analyze`、`flutter test` 全部通过。
2. adapter 单元测试覆盖 W3C 生成/继续/非法值、HTTP 注入、IM envelope 注入、ERROR event 脱敏、有界 flush 和幂等 shutdown。
3. 用可观察的测试 exporter 断言 Span Status/Event/属性，测试进程不依赖真实 Collector。
4. 代码扫描确认业务层不直接导入第三方 OTel SDK，构建产物不包含固定 ingest Token。
5. 在 Android 和 iOS 真机/模拟器上验证 HTTP -> Server 与 IM AUTH -> SEND -> ACK 传播；Exporter 断网/超时时业务仍成功。
6. 只有受鉴权 ingest gateway 上线后，才执行 App -> OTLP -> Jaeger 的测试环境公网验收和脱敏扫描。

上述门槛未完成前，只能说“Flutter telemetry 契约已定义”，不能说“Flutter Trace 已接入”。
