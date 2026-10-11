# such_music

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## 真实联网冒烟测试（可选，默认跳过）

普通 `flutter test` 会**跳过**所有联网用例（离线 / CI 环境安全）。
需要显式验证「扫码登录 + 搜索 + 取播放地址」真实链路时，用一行命令开启 `LIVE=1`：

```bash
export PATH=/opt/flutter/bin:$PATH
flutter test --dart-define=LIVE=1 test/live/kugou_live_smoke_test.dart --reporter expanded
```

> 也支持环境变量：`LIVE=1 flutter test test/live/kugou_live_smoke_test.dart`。
> 覆盖：取二维码 → 轮询（预期 waiting）→ 搜索（预期非空且字段完整）→
> 搜索取播放地址（断言 `error_code != 20006`，即签名盐值正确）。

