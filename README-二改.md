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
- **酷狗概念版凭证**：点击进入凭证页，提供 **3 种** 配置方式：
  - **扫码登录（推荐，v1.1 新增）**：点「扫码登录」→ 用**酷狗概念版 App** 扫码 → 手机上确认 →
    自动拿到 `token`/`userid` 并写入。二维码优先用接口直返的 base64 图片，缺失时回退 `qr_flutter`
    渲染；过期或本地 TTL 到期**自动换码**；退出页面会**取消**在飞请求与轮询。轮询间隔 2s，
    连续 5 次网络错误或超时即停止（不无限刷风控）。
  - **粘贴凭证（v1.1 新增兜底）**：点「粘贴凭证」，粘贴整段 cookie 或 JSON
    （如 `token=...; userid=...` 或 `{"token":"...","userid":123}`），自动提取并保存。
  - **手工填写（高级 / 兜底）**：直接填 `token` / `userid`（可从酷狗概念版 App 抓包获得），
    可选填昵称用于展示。
  凭证本地保存、界面与日志**一律脱敏**（`前4****后4`，`AppConstants.maskToken`）。

> 未配置凭证时选择酷狗会先引导你去配置，不会清空网易云登录态。

### 1.1 v1.1 两处缺陷修复

| 编号 | 缺陷 | 修复位置 | 说明 |
|---|---|---|---|
| **REQ-L2** | 搜索**主路径**用的 `mobilecdn.kugou.com` 实测**完全不可达（HTTP 000）**，导致搜索主路径失效 | `lib/services/sources/kugou_source.dart`（`search` / `_searchComplex` / `_searchMobileCdn`） | 主路径改为实测可用的 `complexsearch.kugou.com/v2/search/song`，并补全**完整签名参数集**（`keyword/page/pagesize/bitrate=0/isfuzzy=0/inputtype=0/platform=WebFilter/userid/iscorrection=1/privilege_filter=0/filter=10/token=` + 公共参数）；`mobilecdn` **降级为兜底**（仅在主路径返回空时调用，且容忍其失败）。 |
| **REQ-L3** | 取播放地址 `key` 的**盐值未按平台区分**，概念版使用了标准版盐值 | `lib/services/sources/kugou_config.dart`（`keySaltLite` / `keySaltStandard`）、`lib/services/sources/kugou_sign.dart`（`playKey(..., {salt})`）、`kugou_source.dart`（`getSongUrl` 传 lite 盐） | 概念版（lite）盐 `185672dd…` 与标准版盐 `57ae12eb…` 分离；登录签名盐 `NVPh5oo7…`（`loginSecret`）与搜索/取地址盐 `LnT6xpN3…`（`secret`）分离——两套签名体系不可混用。 |

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
| `flutter test` | ✅ **163 / 163 通过** | 13 个测试文件（v1.1 在既有 105 项之上**新增 58 项**：登录服务状态机 / 二维码组件 / 凭证解析 / 搜索主路径 / 登录签名黄金值 / 回归护栏） |
| 扫码登录签名单测（真实黄金向量） | ✅ 通过 | 取码 `bc87e873…`、轮询 `79c26d9f…`、概念版 `playKey` `e4070a69…`、标准版 `584a651d…`（由独立脚本核算并断言） |
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
3. 本版**不做**音质选择、**不做短信验证码登录、不做跳转酷狗 App 授权登录（OAuth）**、不接入小米超级岛官方审核通道（见 PRD「非目标」）。
   - **短信验证码登录**未实现：实测 `POST login.user.kugou.com/v7/send_mobile_code` 持续返回 `error_code=20006`（签名错），
     且依赖**设备注册上下文**，真实校验必须使用真实手机号，当前环境无法验证。
   - **跳转 App 授权登录（OAuth）**未实现：需**酷狗开放平台**开发者资质（appid/secret + 回调），个人二改无法获得；
     即便获得也**取不到概念版播放凭证**。
   - 登录服务已预留 `QrLoginState.confirmed`（接口未见）等扩展位，后续拿到稳定链路可接入。
4. 本项目仅供学习研究，请尊重版权；VIP 权益完全依赖使用者自有的合法账号凭证，本项目不破解、不伪造。
