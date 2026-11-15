# 歌曲分享接入 Wrensong

> 版本：1.5.2 起。协议依据 <https://wrensong.lztech.top/open/docs>（2026-11 核对）。
> 代码：`lib/services/share/wrensong_share_service.dart`（决策 + payload）、
> `android/app/src/main/kotlin/com/lightningteam/suchmusic/WrensongShareBridge.kt`（原生桥）。

## 1. 一句话

播放页「分享」不再只复制文本：装了 Wrensong 就**直接唤起对方的分享面板**（歌名 / 歌手·专辑 /
封面 / 可播放直链），没装或失败才退回「复制歌曲信息」这条老路。

## 2. 唤起参数

| 项 | 值 |
|---|---|
| Action | `top.lztech.wrensong.ACTION_SHARE` |
| 目标包（**必须** `setPackage`） | `top.lztech.wrensong` |
| Category | `android.intent.category.DEFAULT` |
| `app_id` (String extra) | `wr_app_ccd99a251a27` |
| `payload` (String extra) | JSON 文本，**总长 ≤ 8KB** |

补充：

- **必须**加 `FLAG_GRANT_READ_URI_PERMISSION` + `clipData` 才能让对方读到 `thumb`
  （见 §2.1）；早期文档写的「无需 flag」只适用于 `exported=true` 的宽松 provider。
- 桥持有 `applicationContext`，因此 intent 必须带 `FLAG_ACTIVITY_NEW_TASK`，
  否则抛的是 `AndroidRuntimeException` 而不是 `ActivityNotFoundException`。
- Android 11+ 包可见性：`AndroidManifest.xml` 的 `<queries>` 必须声明
  `<package android:name="top.lztech.wrensong"/>`，否则 `getPackageInfo` /
  `resolveActivity` 查不到已安装的 Wrensong，会被误判成「未安装」。

### 2.1 缩略图权限（`content://` 必须显式授权）

`thumb` 是 `FileProvider` 的 `content://` URI，而我们的 provider 是
`android:exported="false"`：**不显式授权，对方 `openInputStream` 一定抛
`SecurityException`**。这个失败是「静默」的——分享本身成功、面板正常拉起，
只有封面丢了；截图看不出来、自动化测试也看不出来，只能靠真机分享一次才发现。

因此 `WrensongShareBridge.share()` 在拿到 URI 后必须做两步：

```kotlin
if (thumbUri != null) {
    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    intent.clipData = ClipData.newRawUri("thumb", Uri.parse(thumbUri))
}
```

为什么要**同时**用 flag 和 clipData：

- `FLAG_GRANT_READ_URI_PERMISSION` 只作用于「本 intent 里被系统识别到的 URI」，
  也就是 `intent.data` 或 `intent.clipData` 里列出的 URI；
- 我们的正文走 `putExtra("payload", json)`，`thumb` 只是 JSON 字符串里的一个字段，
  系统**不知道**它是个 URI —— 只有把它放进 `clipData`，flag 才有作用对象。

为什么这样授权是「精确」的（不放开整个 provider）：

- `setPackage(TARGET_PACKAGE)` 已把 intent 的目标锁死为 Wrensong，flag 只授予
  **这一个包**；
- `clipData` 只声明**这一条** URI，`cacheDir` 下其它文件依然读不到；
- 授权是临时的（随对方进程/任务存续），不是永久权限，对方进程结束后自动失效；
- 绝不能改成 `android:exported="true"` 或全局 `grantUriPermissions` —— 那会把
  整个 provider 暴露给任何应用。

换 provider / 换目录时要注意：

1. `provider` 必须是 `androidx.core.content.FileProvider`
   （`exported="false"` + `grantUriPermissions="true"`），`authorities` 与代码里的
   `"${context.packageName}.fileProvider"` 保持一致；
2. `res/xml/*_paths.xml` 里的 `<cache-path>` 必须覆盖缩略图实际落盘的目录
   （当前 `cacheDir/wrensong_thumb_*`），换目录而不改 xml → `getUriForFile` 直接抛
   `IllegalArgumentException`；
3. 缩略图有生命周期：`share()` 每次会清理 1 小时前的旧图。对端必须**拿到就拷贝**
   （协议如此）；若某个版本对端改为延迟读取，需要同步放大 `THUMB_RETENTION_MS`。

## 3. payload 字段映射

| 字段 | 类型 | 约束 | SuchMusic 的取值 |
|---|---|---|---|
| `type` | String | `link`/`image`/`video`/`file`/`music` | 拿到直链 → `music`；否则 → `link`；本地曲目**不分享** |
| `title` | String | ≤64 字，必填 | `song.name`，按 runes 截断到 64 |
| `desc` | String | ≤120 字，可选 | `歌手 · 专辑`；专辑为空只写歌手；按 runes 截断到 120 |
| `url` | String | `link` 必填，仅 http(s) | 酷狗 `https://www.kugou.com/song/#hash=<id>`；网易云 `https://music.163.com/song?id=<id>` |
| `music_url` | String | `music` 必填 | `SourceManager().withFallback(getSongUrl)` 取到的播放直链（4s 超时） |
| `thumb` | String | `content://` URI，可选 | 封面 URL 下载（≤2MB）→ 原生压缩 → FileProvider URI（读权限见 §2.1） |

为什么 `title` / `desc` 按 **runes** 截断：emoji 是代理对，按 code unit 截会切出半个字符，
传到对端就是乱码。

## 4. 降级矩阵

| 场景 | 结果类型 | 用户看到 |
|---|---|---|
| 唤起成功 | `ok` | 无 toast（Wrensong 面板已在前台） |
| 未安装 Wrensong（`resolveActivity == null` / `ActivityNotFoundException`） | `notInstalled` | 复制 `歌名 - 歌手\n链接` + 「未安装 Wrensong，已复制歌曲信息」 |
| 本地曲目（没有可传的 URL） | `notSupportedLocal` | 复制，链接位写「本地文件」+ 「本地歌曲已复制信息」 |
| 原生返回 `security` / `error` / 桥接抛异常 | `failed` | 复制 + 「分享未完成，已复制歌曲信息」 |

原则：**分享是一次点击要么拉起对方面板、要么给一份可粘贴文本**，不允许出现「点了没反应」。

分享期间按钮 label 变「分享中」且 `onTap` 置空（`_sharing` 防连点，`finally` 复位）。

## 5. 原生桥方法签名

Channel：`com.lightningteam.suchmusic/wrensong_share`（Kotlin `WrensongShareBridge.CHANNEL`）

| 方法 | 入参 | 返回 |
|---|---|---|
| `isInstalled` | – | `Boolean` |
| `share` | `appId: String`、`payload: Map<String, Any?>`、`thumbBytes: ByteArray?` | `{ok: true}` 或 `{ok: false, reason: "not_installed"｜"security"｜"payload_too_large"｜"error"}` |

原生侧职责边界（**不做业务决策**）：

1. payload 用 `org.json.JSONObject` 序列化（不手拼字符串）；序列化后 UTF-8 > 8KB 时
   去掉 `thumb` 重试一次，仍超 → `payload_too_large`。
2. 封面：`BitmapFactory.decodeByteArray` → 长边 `min(480, max(240, 原长边))` → `JPEG 80`；
   >64KB 时依次降质量 70/60、缩长边 320/240 重试；仍 >64KB → 丢弃 `thumb`（不影响分享）。
   落盘 `cacheDir/wrensong_thumb_<uuid>.jpg` → `FileProvider.getUriForFile(context,
   "${packageName}.fileProvider", file)` → 返回 `String?` URI，**只生成不授权**。
3. `share()` 拿到 URI 后把 `FLAG_GRANT_READ_URI_PERMISSION` + `clipData` 挂到 intent 上
   （见 §2.1）；payload 因超 8KB 裁掉 `thumb` 时，同步把 `thumbUri` 置空，不留悬空授权。
4. 每次 `share` 顺带清理 `cacheDir` 下超过 1 小时的 `wrensong_thumb_*`（失败不影响主流程）。

## 6. 换 app_id / 换目标包

- **换 app_id**：改 `WrensongShareService.appId`（`lib/services/share/wrensong_share_service.dart`
  顶部常量）一处即可，测试断言也从该常量读，不会漏改。
- **换目标包名**：三处必须同步，缺一处就会「装了也判成未安装」：
  1. `WrensongShareBridge.TARGET_PACKAGE`（Kotlin）；
  2. `ACTION_SHARE` 的动作字符串由对方提供，一般随包名变；
  3. `AndroidManifest.xml` 的 `<queries><package android:name="…"/>`。

## 7. 未安装 / 未在开放平台登记时的表现

| 情况 | 表现 |
|---|---|
| 设备未装 Wrensong | `isInstalled` 返回 false → 不唤起、不弹系统「选择应用」框；复制信息并提示「未安装 Wrensong」 |
| `app_id` 未登记 / 被停用 | **本 App 无感知**（协议无同步校验接口，也没有回调）。Wrensong 侧自行提示错误；SuchMusic 侧看起来是「正常唤起」 |
| Wrensong 已装但 `ACTION_SHARE` 无人响应 | `resolveActivity` 为 null → 按未安装降级（不会静默失败） |
| 分享途中被杀进程 | 无回调，本 App 只负责把面板拉起来，后续归 Wrensong |

## 8. 测试

- `test/wrensong_share_test.dart`：安装状态分支、`music`/`link` 两种 payload、
  本地曲目、桥接异常、title/desc 截断、payload ≤8KB、降级文案。
- `test/player_landscape_parity_test.dart`：横屏各尺寸下分享入口真的在屏内（见下条）。
- 原生压缩 / 唤起只能在真机验证：`cd android && ./gradlew :app:compileDebugKotlin` 只保证编译，
  实际行为需装 Wrensong 的手机上点一次分享。
- **缩略图尤其要真机看一眼**：读权限没给时分享照样成功，只是封面没了 —— 截图、
  自动化测试、crash 日志都不会报，只有对方面板上「有没有封面」这一眼看得出。
