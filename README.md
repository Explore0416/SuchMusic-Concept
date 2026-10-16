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

## 手环桥接（小米手环 · 概念版）

概念版支持用**小米手环**控制播放（播放 / 暂停 / 切歌 / 进度），并在手环端查看当前歌名与状态。
手机端是唯一持有小米 Wearable SDK 的一端；手环端快应用由独立仓库实现（`system.interconnect`）。
通信协议、字段清单与时序见 `docs/ARCH-手环通信.md` 与 `docs/sequence-band.mermaid`。

### 为什么默认没有手环通信

小米官方 SDK（`xms-wearable-lib` AAR）**专有许可不允许随仓库分发**，因此本仓库**默认不含**它：

- 没有该 AAR 时，**构建完全正常**，App 其它功能不受影响；
- 手环页面会如实显示「**SDK 未就绪**」，快应用安装状态显示「未知」；
- 桥接层对 SDK 的调用全部收敛在**薄适配层**里，并用**反射**访问 `com.xiaomi.xms.wearable.*`
  （无编译期硬依赖）。SDK 缺失时自动回退到 `NoopBandAdapter`。

### 启用步骤（真机通信）

把 AAR 交给构建有两种方式，**均合规**——AAR 只对构建过程可见，不进入任何公开产物。

**方式 A · 本地构建（手动放置）**

1. 取得官方 AAR `xms-wearable-lib_1.4_release.aar`（随官方《小米穿戴第三方 APP 能力开放接口文档 v1.4》提供）。
2. 放到 `android/app/libs/` 下（文件名需匹配 `xms-wearable-lib*.aar`；该目录已被 `.gitignore` 忽略，**不会入库**）。
3. 重新构建：

   ```bash
   export PATH=/opt/flutter/bin:$PATH
   flutter build apk --release --target-platform android-arm,android-arm64 \
     --build-name=<版本> --build-number=<编号>
   ```

**方式 B · CI 构建时自动拉取（推荐：发布版自动带 SDK）**

`.github/workflows/android-build.yml` 在 `flutter build apk` 前自动从**私有 Release 资源**拉取 AAR 到
`android/app/libs/`，编译进 APK 后随运行器销毁。启用只需在**本仓库** Actions secrets 配置一项：

| Secret | 内容 |
|---|---|
| `WEARABLE_AAR_PAT` | 可读取私有库 `SuchMusic-Band` Release 资源的 PAT |

> AAR 存放于私有库 `Explore0416/SuchMusic-Band` 的 Release（tag `xms-wearable-lib`）。
> 未配置该 secret（如公开 fork）时步骤自动跳过 → 优雅降级为 Noop，构建照常通过。

构建脚本仅在**检测到该 AAR 存在**时才把它加入依赖（见 `android/app/build.gradle.kts`
中的 `fileTree("libs") { include("xms-wearable-lib*.aar") }`），因此缺少它时构建照常通过。

### 手环端（两种方式通用）

1. 把 `SuchMusic` 快应用（**包名与签名必须与手机 App 完全一致**）安装到已与手机配对的手环上，
   并在「小米运动健康 → 设备 → 第三方应用 / 授权」中为其授权设备互联。
2. 打开 App「设置 → 手环」→ 开启「启用手环控制」；进手环端 `SuchMusic` 首页即可看到当前播放。

> 包名 / 签名任一处不一致 → 通信会被**静默拒绝**。证书从 `android/keystore/suchmusic-release.jks`
> 导出（步骤见 `docs/ARCH-手环通信.md` §6.2）。

### 隐私

手环与手机**仅通过本机配对链路**（蓝牙 / 系统互联通道）通信，命令与状态**不经任何服务器、不上传**；
手环端不保存账号凭证、歌词全文与歌单。手环功能默认关闭，可在「设置 → 手环」启用或停用。

