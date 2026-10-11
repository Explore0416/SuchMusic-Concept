# SuchMusic 二改说明

本仓库基于 [`sunset5277/SuchMusic`](https://github.com/sunset5277/SuchMusic) 做二次开发。
本文件说明**改了什么、怎么构建、怎么用、哪些已验证/未验证**。

设计文档见 `docs/`：`PRD-二改.md`（需求规格）、`ARCH-二改.md`（架构与任务分解）、`QA-二改-报告.md`（验证报告）。

---

## 一、本次二改的四项需求

| 需求 | 实现要点 | 对应代码 |
|---|---|---|
| **1. 横屏 / 平板适配（含小米平板）** | 新增响应式「单一真源」`Responsive`，按最短边划分 5 档断点 B1~B5：手机竖屏 / 手机横屏 / 平板竖屏 / 平板横屏 / 超宽屏。平板与横屏下：底部胶囊栏 → 左侧 `NavigationRail`；播放页改为「左封面+控制 / 右歌词」分栏；首页改多列网格；内容区限宽 960dp 居中；封面封顶 420dp。原有 12 处硬编码尺寸点全部替换为响应式取值。 | `lib/utils/responsive.dart`、`lib/widgets/responsive_scaffold.dart`、`lib/main.dart`、各 `lib/screens/*` |
| **2. 小米无极缩放 + 灵动岛歌词** | ① `resizeableActivity="true"` + 保留 `configChanges`（旋转/缩放不重启 Activity，播放不中断）；② 全局字体缩放夹取 `[0.85, 1.3]` 防溢出；③ **歌词写入系统媒体通知副标题**（`MediaItem.artist`），全 Android 生效，小米灵动岛/超级岛区域、锁屏、通知栏均可显示；④ 额外提供小米超级岛增强（MethodChannel + `miui.focus.param`），**先做设备能力检测，不支持/未授权则静默跳过**，绝不阻断播放。 | `lib/services/notification_lyric_service.dart`、`lib/services/island_service.dart`、`lib/services/audio_player_handler.dart`、`android/.../IslandBridge.kt`、`android/.../MainActivity.kt`、`AndroidManifest.xml` |
| **3. 酷狗概念版音源** | 新增音源抽象层：搜索 / 取播放地址 / 歌词 / 详情。使用**酷狗概念版（appid 1005）**参数取地址，可播放概念版 VIP 资源；签名算法自实现（MD5），常量集中可热修。支持音源切换、失败自动回退网易云（回退时按「歌名+歌手」解析出网易云对端歌曲，而不是拿酷狗 ID 去请求网易云）。 | `lib/services/sources/*`、`lib/services/kugou_credential_service.dart`、`lib/screens/kugou_credential_page.dart` |
| **4. 不出现 Bug** | 修复了原仓库**无法在他人机器构建**的问题（`pubspec.yaml` 里 `netease_music_api` 是硬编码 Windows 路径 `D:/laji/...`）。已 vendor 到 `packages/netease_music_api` 并补回上游缺失的 `n` 参数。静态分析 0 issue，105 个单元测试全绿。 | `pubspec.yaml`、`packages/netease_music_api/` |

---

## 二、构建

```bash
# 需要 Flutter 3.47+（Dart 3.13+）与 Android SDK
flutter pub get
flutter build apk --debug     # 或 --release
```

> **国内网络提示**：若拉取 Flutter 引擎/依赖很慢或卡住，先切换官方中国镜像再构建：
>
> ```bash
> export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
> export PUB_HOSTED_URL=https://pub.flutter-io.cn
> ```
>
> （仓库 `android/settings.gradle.kts` 已内置阿里云 Maven 镜像。）

> **注意**：`android/app/build.gradle.kts` 的 `signingConfigs.release` 会读取 `android/key.properties`，
> 该文件不在版本库中。打 **release** 包前需自备签名：
>
> ```properties
> # android/key.properties
> storePassword=你的口令
> keyPassword=你的口令
> keyAlias=你的别名
> storeFile=你的.jks
> ```
>
> 若本机 Gradle 可用内存有限，请调低 `android/gradle.properties` 的 `org.gradle.jvmargs`
> （默认 `-Xmx8G -XX:MaxMetaspaceSize=4G`，在 8G 内存的容器中会被 OOM 杀掉）。

---

## 三、使用

### 1. 音源切换

「我的 → 设置 → 音源」：

- **当前音源**：网易云 / 酷狗概念版。
- **失败自动回退**：酷狗取源失败时自动改用网易云（默认开）。
- **酷狗概念版凭证**：点击进入凭证页，填入 `token` / `userid`（可从酷狗概念版 App 抓包获得），
  可选填昵称用于展示。凭证本地保存、界面与日志**一律脱敏**（`前4****后4`）。

> 未配置凭证时选择酷狗会先引导你去配置，不会清空网易云登录态。

### 2. 通知栏 / 灵动岛歌词

「设置 → 播放设置 → 通知栏 / 灵动岛显示歌词」（默认开）。
开启后，系统媒体通知的**副标题**会随歌词逐行更新（节流 ≤2 次/秒，仅文本变化时刷新），
在小米 HyperOS 的灵动岛 / 超级岛区域、锁屏与通知栏可看到当前歌词。
关闭开关后，副标题恢复为「歌手 - 专辑」，且**不会打断播放**。

> 小米「超级岛」的完整官方能力需要上架小米应用商店并通过官方审核授权。
> 本版采用**通知副标题**方案（免审核、全 Android 生效），并附带超级岛客户端增强：
> 设备支持且已授权时自动启用，否则静默降级。

### 3. 横屏 / 平板

直接旋转设备或在大屏 / 分屏 / 自由窗口下使用即可，无需手动开关。
平板形态会自动切换左侧导航栏与分栏播放页。

---

## 四、验证状态

| 项 | 状态 | 证据 |
|---|---|---|
| `flutter analyze lib test` | ✅ **0 issues** | 与改造前基线一致（原基线有 1 个 error，已随依赖修复清零） |
| `flutter test` | ✅ **105 / 105 通过** | 8 个测试文件 |
| 竖屏基线不回归（430×932） | ✅ 单元测试固化 | 胶囊栏 321.5 / 封面 380 / uiScale 1.0 / dialogScale 1.0 |
| 原生 Kotlin 编译（`MainActivity.kt` + `IslandBridge.kt`） | ✅ **编译通过** | 用 Kotlin 2.3.20 编译器 + `android.jar(API 36)` + Flutter embedding + audio_service 实际编译，产出 `MainActivity.class` / `IslandBridge.class`（仅原有 deprecated 警告） |
| Android 构建管线（Gradle 配置 / 清单合并 / 资源处理 / R 类生成 / 全部插件编译） | ✅ 通过 | 端到端跑通 |
| 完整 `flutter build apk` | ✅ **构建成功** | 产出 `app-debug.apk`（160MB，minSdk 24 / targetSdk 36，ABI：arm64-v8a / armeabi-v7a / x86_64）；已用 aapt 校验清单 `resizeableActivity=true`、无 `screenOrientation`、权限与服务齐全；dex 内含 `IslandBridge` / `miui.focus.param` / `com.such.music/island`，`kernel_blob.bin` 内含新增 Dart 逻辑 |
| 酷狗接口真实可用性 | ⚠️ **未验证**（需联网 + 有效凭证） | 参数与签名算法已按逆向结论实现并单测 |
| 小米灵动岛 / 超级岛真机呈现 | ⚠️ **未验证**（需小米真机与系统授权） | 能力检测 + 静默降级逻辑已实现 |
| 多尺寸真机无溢出走查 | ⚠️ 布局逻辑已被单测覆盖，真机视觉走查待补 | — |

---

## 五、已知限制与声明

1. **酷狗接口为第三方逆向接口**，其参数、密钥、返回结构可能随时变更。本版已做
   「常量集中 + 失败回退网易云 + 请求竞态保护」，但仍存在失效风险。
2. 酷狗歌词使用明文 LRC（`fmt=lrc`），**不解密 KRC**。
3. 本版**不做**音质选择、不做扫码登录、不接入小米超级岛官方审核通道（见 PRD「非目标」）。
4. 本项目仅供学习研究，请尊重版权；VIP 权益完全依赖使用者自有的合法账号凭证，本项目不破解、不伪造。
