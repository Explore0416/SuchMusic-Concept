# SuchMusic 二改说明

> **当前版本 1.2.0**（2026-10-25）：已**同步官方 1.2.0**（逐字歌词 / 桌面悬浮歌词 /
> 播放页重做 / 首页本地标签 / 搜索改版），并保留二改全部能力（酷狗音源、本地加密音频解密、
> 点赞与歌单、猜你想听、手环互联、原生音效、后台下载更新）。
>
> **许可证：AGPL-3.0**。上游自 1.2.0 起采用 AGPL v3，本项目合并其代码后同样以 AGPL-3.0 发布，
> 完整源码见本仓库。手环端（Vela 快应用，独立实现）另见
> [`SuchMusic-Band`](https://github.com/Explore0416/SuchMusic-Band)，仍为 MIT。

本仓库基于 [`sunset5277/SuchMusic`](https://github.com/sunset5277/SuchMusic) 做二次开发。
本文件说明**改了什么、怎么构建、怎么用、哪些已验证/未验证**。

设计文档见 `docs/`：`PRD-二改.md`（需求规格）、`ARCH-二改.md`（架构与任务分解）、`QA-二改-报告.md`（验证报告）。

---

## 一、本次二改的四项需求

| 需求 | 实现要点 | 对应代码 |
|---|---|---|
| **1. 横屏 / 平板适配（含小米平板）** | 新增响应式「单一真源」`Responsive`，按最短边划分 5 档断点 B1~B5：手机竖屏 / 手机横屏 / 平板竖屏 / 平板横屏 / 超宽屏。**竖屏（手机 B1 / 平板 B3）与手机横屏 B2 一律沿用原版底部悬浮胶囊栏**；**横屏大屏（B4 / B5）**改为 PC 风格「左侧边栏 + 底部全宽常驻播放条」；播放页横屏改「左封面+控制 / 右歌词」分栏；首页平板改多列网格；内容区限宽 960dp 居中；封面封顶 420dp。原有 12 处硬编码尺寸点全部替换为响应式取值。 | `lib/utils/responsive.dart`、`lib/widgets/responsive_scaffold.dart`、`lib/main.dart`、各 `lib/screens/*` |
| **2. 小米无极缩放 + 灵动岛歌词** | ① `resizeableActivity="true"` + 保留 `configChanges`（旋转/缩放不重启 Activity，播放不中断）；② 全局字体缩放夹取 `[0.85, 1.3]` 防溢出；③ **歌词写入系统媒体通知副标题**（`MediaItem.artist`），全 Android 生效，小米灵动岛/超级岛区域、锁屏、通知栏均可显示；④ 额外提供小米超级岛增强（MethodChannel + `miui.focus.param`），**先做设备能力检测，不支持/未授权则静默跳过**，绝不阻断播放。 | `lib/services/notification_lyric_service.dart`、`lib/services/island_service.dart`、`lib/services/audio_player_handler.dart`、`android/.../IslandBridge.kt`、`android/.../MainActivity.kt`、`AndroidManifest.xml` |
| **3. 酷狗概念版音源** | 新增音源抽象层：搜索 / 取播放地址 / 歌词 / 详情。使用**酷狗概念版（lite，appid 3116 / clientver 11440）**参数取地址，可播放概念版 VIP 资源；签名算法自实现（MD5），常量集中可热修。支持音源切换、失败自动回退网易云（回退时按「歌名+歌手」解析出网易云对端歌曲，而不是拿酷狗 ID 去请求网易云）。另支持酷狗原版（standard）。 | `lib/services/sources/*`、`lib/services/kugou_credential_service.dart`、`lib/widgets/kugou_login_dialog.dart` |
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

- **当前音源**：网易云 / 酷狗概念版 / 酷狗音乐。
- **失败自动回退**：酷狗取源失败时自动改用网易云（默认开）。
- **酷狗账号登录（内测 0.9.0 起）**：在「我的」页点对应音源的「扫码登录」，弹出与**网易云一致的
  扫码弹窗** → 用「酷狗概念版 / 酷狗音乐 App」扫码 → 手机上确认 → 自动拿到 `token`/`userid` 并写入。
  二维码优先用接口直返的 base64 图片，缺失时回退 `qr_flutter` 渲染；过期或本地 TTL 到期**自动换码**；
  关闭弹窗会**取消**在飞请求与轮询。轮询间隔 2s，连续 5 次网络错误或超时即停止（不无限刷风控）。
  扫码不便时，弹窗内提供「手动输入凭证」兜底：粘贴整段 cookie / JSON（如 `token=...; userid=...`）自动解析。
  凭证本地保存、界面与日志**一律脱敏**（`前4****后4`，`AppConstants.maskToken`）。
  已登录后可在「设置 → 酷狗账号」中「重新扫码登录」或「退出登录」。

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
| 完整 `flutter build apk` | ✅ **构建成功** | 产出 `app-debug.apk`（160MB，minSdk 24 / targetSdk 36，ABI：arm64-v8a / armeabi-v7a / x86_64）；已用 aapt 校验清单 `resizeableActivity=true`、无 `screenOrientation`、权限与服务齐全；dex 内含 `IslandBridge` / `miui.focus.param` / `com.lightningteam.suchmusic/island`，`kernel_blob.bin` 内含新增 Dart 逻辑 |
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

---

## 六、概念版（lite）平台参数修正（v1.2.0）

### 问题

此前音源虽名为「酷狗概念版」，但请求使用的是**酷狗普通版（标准版）的应用标识**
`appid=1005 / clientver=20489`，导致：

- 扫码登录授权到的是**酷狗音乐（普通版）**，而非酷狗概念版；
- 服务端按普通版身份校验权益，**概念版 VIP 无法生效**。

### 修正

参照 KuGouMusicApi 的双版本架构（`util/config.json`），酷狗概念版（lite）与标准版参数为：

| 参数 | 标准版 standard | 概念版 lite（本次采用） |
|------|-----------------|------------------------|
| appid | 1005 | **3116** |
| clientver | 20489 | **11440** |
| 登录二维码内容 `qrcode_txt` 的 appid | 1005 | **3116** |

改动点（均在 `lib/services/sources/`）：

1. `kugou_config.dart`：新增 `liteAppid=3116` / `liteClientver=11440`（与 `standardAppid/standardClientver` 并列保留），
   并将 `appid` / `clientver` / `loginClientver` / `qrTxt` 全部切换到**概念版 lite** 参数；
2. `kugou_source.dart`：搜索、取播放地址自动使用新配置（概念版 `appid=3116` + 概念版 android 盐 + 概念版 key 盐）；
3. `lib/widgets/kugou_login_dialog.dart`（原 `kugou_credential_page.dart`，0.9.0 起改为登录弹窗）：
   弹窗与扫码区文案按所选平台显示为「酷狗概念版」/「酷狗音乐」，并提示用对应 App 扫码。

> 说明：`qrcode_txt` 中的 `appid` 决定扫码授权的目标平台，是本次修复的关键。

### 验证

| 项 | 方式 | 结果 |
|----|------|------|
| 取二维码 | 真实联网 | ✅ 返回有效二维码（data URI） |
| 轮询状态 | 真实联网 | ✅ 未扫码返回等待态 |
| 搜索 | 真实联网 | ✅ `complexsearch` 主路径非空（概念版参数签名通过） |
| 取播放地址 | 真实联网 | ✅ 无 `error_code=20006`（签名盐值正确） |
| 离线单测 | `flutter test` | ✅ 197 passed / 5 skipped |
| 静态分析 | `flutter analyze lib test` | ✅ 0 issues |

> ⚠️ 「扫码后 token 是否绑定概念版权益」需在真机用**自有概念版 VIP 账号**实测确认。

---

## 七、播放失败修复：设备注册 + /v5/url 取直链（v1.3.0）

### 现象

酷狗登录成功、搜索正常，但**一放歌就回退网易云**（提示「播放失败，请检查网络或登录状态」）。

### 根因（实测定位）

1. 取播放直链的接口（`/v3/url`、`/v5/url`）对**未注册设备**返回
   `20028 本次请求需要验证`（风控）→ `getSongUrl` 得到空 → 上层回退网易云；
2. 旧实现用的是**进程内随机 dfid**、且 mid 为 32 位 hex —— 酷狗「设备注册」接口
   **只接受纯数字 mid**，hex mid 会被拒绝（返回空 `data`），拿不到真实 `dfid`；
3. 即便注册成功，mid/dfid **未持久化**，重开 App 后即失效。

### 修复

新增/改造（`lib/services/sources/`）：

| 文件 | 变更 |
|------|------|
| `kugou_crypto.dart` | **新增**：AES-CBC/PKCS7、RSA-PKCS#1 v1.5、ASN.1 解析 PEM（供设备注册） |
| `kugou_device_service.dart` | **新增**：`register_dev`（`userservice.kugou.com/risk/v2/r_register_dev`）拿真实 `dfid`，含**重试**与**持久化** |
| `kugou_device.dart` | mid 改**纯数字 32 位**；mid/guid/dfid 可持久化注入；dfid 可写 |
| `kugou_source.dart` | 取直链改用 **`/v5/url`**（`x-router: trackercdn.kugou.com`），参数对齐 KuGouMusicApi `song_url.js`；兼容响应在**顶层**或 `data` 下、以及 `text/plain` 未解码的 String |
| `kugou_config.dart` | 新增注册接口、`/v5/url` 常量、概念版 RSA 公钥、Android UA/公共头 |
| `main.dart` | 启动时后台触发设备注册（失败静默，取链时会自动重试） |

关键实现对齐 KuGouMusicApi（已验证可用的开源实现）：
- 设备注册 body = AES(设备信息)；会话串 `p` = RSA(概念版公钥)；签名含 body 串；
- 取直链 `key = md5(hash + 概念版key盐 + appid + mid + userid)`，签名用概念版 android 盐；
- 直链 URL 形如 `.../ap3116_df<dfid>_pi411_mx0_qu128_...mp3`（`ap3116` = 概念版）。

### 验证（真实联网，沙箱实测）

| 项 | 结果 |
|----|------|
| 设备注册 `register_dev` | ✅ 返回真实 dfid |
| 取二维码 / 轮询 | ✅ 正常 |
| 搜索 | ✅ 非空 |
| **取播放直链** | ✅ 返回真实 `.mp3`（HTTP 200/206，`audio/mpeg`） |
| 离线单测 | ✅ 202 passed / 6 skipped |
| 静态分析 | ✅ 0 issues |

> ⚠️ 说明：设备注册在**同一 IP 高频请求时会被限流**（返回空 `data`），已加自动重试；
> 真机正常使用（每次安装只注册一次并持久化）通常首次即成功。
> 若升级后登录态失效，重新扫码登录一次即可。

---

## 八、横屏/平板播放控制 + PC 风格布局 + MiSans 字体（v1.4.0）

### 1. 横屏/平板看不到、也控制不了正在播放的歌（修复）

**根因**：`ResponsiveScaffold` 在平板/横屏分支只渲染「左侧 NavigationRail + 内容」，
**完全忽略 `bottomBar`**，导致横屏下没有任何播放控件。

**修复**：新增 `lib/widgets/player_bar.dart` —— PC 风格**全宽常驻播放条**：

| 区域 | 元素 |
|------|------|
| 左 | 封面（48，圆角 8）+ 歌名（加粗）+ 歌手；点击打开播放页 |
| 中 | 播放模式 / 上一首 / 播放暂停（实心圆）/ 下一首 |
| 右 | 时间 `mm:ss / mm:ss` + 打开播放页 |
| 顶 | 细进度线（可点/拖 seek） |

`MainShell` 新增 `isPlaying` / `playMode` 订阅并接入该播放条。

### 2. 横屏参考 PC 版 UI

参照 [SuchMusic-NG](https://github.com/Enzymeym/SuchMusic-NG)（仅参考 UI，未移植）：
平板/横屏改为「**左侧边栏（Logo + 导航项、圆角选中态）+ 右侧内容 + 底部全宽播放条**」，
替换原 Material NavigationRail。手机竖屏布局保持不变（无回归）。

### 3. 全局字体改为 MiSans

打包小米开源免费商用字体 **MiSans**（Regular/Medium/Bold 三个字重），
在 `pubspec.yaml` 声明并在 `ThemeData.fontFamily = 'MiSans'` 全局生效。
> 说明：APK 体积因字体增加约 16MB（65.7MB → 82.1MB）；若需要可改为按需子集化。

### 4. 开发者名单

`about_page.dart` 开发者弹幕新增：**闪电科技团队 / 手机、平板端二次开发**。

### 验证

| 项 | 结果 |
|----|------|
| 新增 PlayerBar 单测 + 平板/手机断点渲染 | ✅ 通过 |
| 多尺寸（320→1600dp）无溢出 | ✅ 通过 |
| 全量单测 | ✅ 211 passed / 6 skipped |
| 静态分析 | ✅ 0 issues |

---

## 九、「我的」页多音源账号 + 酷狗榜单 + 交互动画（v1.5.0）

### 1. 「我的」页支持选择登录酷狗概念版

**问题**：登录酷狗后「我的」页仍只显示「扫码登录网易云账号」，且酷狗登录入口只在设置里。

**修复**：`profile_page.dart` 未登录态由单个按钮改为**音源账号卡片**，三行分别展示：

| 行 | 状态 | 操作 |
|----|------|------|
| 网易云音乐 | — | 扫码登录（弹窗） |
| 酷狗概念版 | 未登录 / 已登录（脱敏 uid） | 扫码登录 / 重新登录 → 打开**扫码弹窗**（与网易云一致） |
| 酷狗音乐 | 未登录 / 已登录（脱敏 uid） | 扫码登录 / 重新登录 → 打开**扫码弹窗**（与网易云一致） |

现在**不需要进设置**，直接在「我的」页就能登录酷狗各平台并看到其登录状态。

### 2. 酷狗榜单（修复「歌单"飙升榜"为空或加载失败」）

**问题**：首页「榜单」固定走网易云接口；切到酷狗音源后点开榜单 → 取不到歌 → 空态。

**修复**：
- `MusicSource` 新增 `rankSongs(playlistId)`；
- `KugouSource` 实现 `topList()`（`GET /ocean/v6/rank/list`，**实测返回 56 个榜单**）
  与 `rankSongs()`（`POST /openapi/kmr/v2/rank/audio`，hash 取 `audio_info.hash_128`）；
- `PlaylistModel` 新增 `source` 字段，**首页榜单与歌单详情页按当前音源分流**；
- 封面加载对酷狗不再追加网易云专用的 `?param=500y500`。

### 3. 交互动画（不再生硬）

- 新增 `widgets/fade_slide_in.dart`：列表逐条**淡入 + 上滑**入场（带延迟阶梯，尊重系统「减弱动态效果」）；
- 新增 `fadeSlideRoute()`：**淡入 + 轻右滑**页面转场，用于歌单详情等；
- 「我的」页登录态切换用 `AnimatedSwitcher` **淡入淡出**，不再跳变；
- 歌单歌曲列表接入逐条入场动画。

### 验证（真实联网）

| 项 | 结果 |
|----|------|
| 酷狗榜单列表 | ✅ 56 个榜单 |
| 酷狗榜单歌曲 | ✅ 非空且带 hash，可播放 |
| 取播放直链 | ✅ 真实 mp3（HTTP 200/206） |
| 全量单测 | ✅ 211 passed / 7 skipped |
| 静态分析 | ✅ 0 issues |

---

## 十、每日推荐 / 私人FM 按音源分流（v1.5.2）

承接第 3 项「适配酷狗概念版功能」的同类问题：**首页每日推荐与私人FM 原本固定走网易云接口**，
酷狗音源下会拿到网易云歌曲 → 取不到播放地址 → 播放失败/空态。

| 入口 | 网易云音源 | 酷狗音源 |
|------|-----------|---------|
| 首页「每日推荐」 | `MusicApiService.getDailyRecommendSongs()` | `KugouSource.dailyRecommend()`（实测 30 首） |
| 私人 FM | `MusicApiService.userRadio()` | 每日推荐**随机取曲**兜底 |

酷狗每日推荐接口：`POST gateway.kugou.com/everyday_song_recommend`
（`x-router: everydayrec.service.kugou.com`，hash 取 `audio_info.hash_128`）。

> FM 说明：酷狗未开放无需资质的个人电台接口（实测 `/v1/get_fm_song` 等均 404），
> 故用已验证的每日推荐做随机播放源，语义一致且带有效 hash。

### 验证（真实联网）

| 项 | 结果 |
|----|------|
| 酷狗每日推荐 | ✅ 30 首，带 hash |
| 酷狗榜单列表 / 歌曲 | ✅ 56 榜 / 可播放 |
| 取播放直链 | ✅ 真实 mp3（HTTP 206） |
| 联网冒烟 | ✅ 8/8 |
| 离线单测 | ✅ 212 passed / 7 skipped |
| 静态分析 | ✅ 0 issues |

---

## 十一、酷狗原版支持 + 歌单导入 + 登录态FM + 播放模式动画（v1.6.0）

### 1. 新增「酷狗音乐」（原版）音源

此前只有「酷狗概念版」。现在音源为三项：**网易云 / 酷狗音乐 / 酷狗概念版**。

关键：两平台是**两套独立参数**（详见 `KugouConfig`）：

| 参数 | 概念版 lite | 原版 standard |
|------|------------|--------------|
| appid / clientver | 3116 / 11440 | 1005 / 20489 |
| Android 签名盐 | `LnT6xpN3…` | `OIlwieks28…` |
| key 盐 | `185672dd…` | `57ae12eb…` |
| 设备注册 RSA 公钥 | lite 公钥 | standard 公钥 |
| 取链 `page_id` / `pid` / `ppage_id` | 967177915 / 411 / `3567…` | **151369488 / 2 / `4634…`** |

> ⚠️ 实测踩坑：`dfid` 与注册时的 `appid` 绑定 —— 用概念版注册的 dfid 请求原版取链会被拒
> （`31833 illegal key` / 风控）。故**设备标识与凭证均按平台分区**（`kugou_dfid_standard` 等）。

### 2. 歌单导入（酷狗 / 酷狗概念版）

新增「我的 → 酷狗歌单」页：

- **查看自己的歌单**（登录态）：`POST /v7/get_all_list`（x-router `cloudlist`）；
- **导入任意歌单**：粘贴歌单链接 / ID（`collection_x_x_x_x`），短链会请求分享页再解析，
  解析出 `global_collection_id` 后进入歌单详情；
- 歌单歌曲：`GET /pubsongs/v2/get_other_list_file_nofilt`（**注意：该接口不带 x-router**）。
- 歌单歌曲 `name` 形如「歌手 - 歌名」，按**最后一个** ` - ` 拆分（歌名可能自带 ` - `）。

### 3. 私人FM 优先走登录态

酷狗登录后走 `POST /v2/personal_recommend`（x-router `persnfm`，需 userid + token，
`key = md5(appid + 盐 + clientver + clienttime)`）；未登录 / 失败仍以
「每日推荐随机取曲」兜底，网易云保持 `userRadio`。

### 4. 播放模式切换动画

点击「顺序 / 单曲 / 随机」按钮此前**瞬间换图标**（视频中「生硬」的来源）。
现改为淡入淡出 + 缩放 + 轻微旋转（320ms，`easeOutCubic`），播放页与横屏播放条一致。

### 验证（真实联网）

| 项 | 结果 |
|----|------|
| 概念版：设备注册 / 取码 / 轮询 / 搜索 / 取直链 | ✅ |
| **原版：搜索 + 取播放直链** | ✅ 真实 mp3 |
| 榜单 56 个 / 每日推荐 30 首 | ✅ |
| **推荐歌单 → 歌单歌曲** | ✅ |
| 联网冒烟 | ✅ **10/10** |
| 离线单测 | ✅ 212 passed / 10 skipped |
| 静态分析 | ✅ 0 issues |

---

## 十二、横屏分栏：歌名/歌手对齐修复（v1.6.1）

### 问题

横屏（分栏）布局中，封面由 `Center` **居中**，但下方的歌名 / 歌手是
`CrossAxisAlignment.start`（**左对齐**）→ 视觉上明显**偏左、与封面不对齐**。

### 修复

`_buildSongInfo` 新增 `center` 参数（居中时同时设置 `crossAxisAlignment` 与
`textAlign`），分栏形态下以 `SizedBox(width: double.infinity)` + 居中渲染，
使歌名 / 歌手与封面共用同一中心轴；竖屏与「收起小封面」形态保持左对齐不变。

> 仅布局对齐调整，无逻辑变更；离线 212 passed / 10 skipped；analyze 0 issues。
