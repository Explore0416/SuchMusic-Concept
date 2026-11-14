# SuchMusic 架构文档

> 本文件是全项目架构的**唯一真源**。分主题历史设计见 `docs/ARCH-*.md`，若与本文件冲突，以本文件为准。
> 每次代码变更涉及接口、数据模型、依赖或目录结构时，必须同步回写本文件并追加变更记录。

- 当前版本：1.5.0（已发布）
- 最后更新：2026-11-14
- 本次范围：`M1` 更新弹窗日志裁剪 + `M2–M6` 第三方授权接入（含 M4 授权界面、M6 通知）

---

## 1. 现状基线

| 能力 | 现状 | 位置 |
|---|---|---|
| 深链 | 无自定义 scheme，仅 `file/content` 音频 VIEW 与 SEND | `AndroidManifest.xml` |
| Intent 通道 | 已有 MethodChannel 接收系统 VIEW intent（本地音频） | `lib/services/local_audio_intent_service.dart` |
| 直链解析 | `MusicApiService.getSongUrlForSong(SongModel)` / `SourceManager.sourceFor(kind)` | `lib/services/music_api_service.dart:917` |
| 播放 | `AudioPlayerService.playSongs(List<SongModel>)` | `lib/services/audio_player_service.dart:1138` |
| 曲风 | `GenreMetadataService.tagIndex`（歌曲→标签权重）、`tagsFor()` | `lib/services/genre_metadata_service.dart` |
| 酷狗令牌 | `KugouCredentialService.tokenOf/userIdOf/nicknameOf(platform)` | `lib/services/kugou_credential_service.dart` |
| 通知 | `notification_lyric_service` 已有通知通道 | `lib/services/notification_lyric_service.dart` |
| 更新 | `UpdateService` 拉 `update.json`，`UpdateChecker` 弹窗 | `lib/services/update_service.dart`、`lib/widgets/update_checker.dart` |

**结论**：数据能力齐备，缺的是「进程间协议 + 授权模型 + 身份校验」三层。

---

## 2. 目标与非目标

### 目标

1. 第三方 App 通过 `suchmusic://` 拉起本 App，按 scope 申请四类能力：
   - `genre.read` 曲风画像
   - `account.token` 酷狗账号令牌
   - `url.resolve` 歌曲直链
   - `playback.control` 由本 App 代播
2. 首次授权强制走确认页，用户逐项可见；之后按 scope 长期有效。
3. 已授权且仅申请可静默 scope 时，无 UI 直接回传最新数据，并发系统通知。
4. 用户可在「设置 → 第三方授权」随时撤销，撤销立即生效。
5. 更新弹窗只显示**本次版本**的更新内容。

### 非目标

- 不做公网 OAuth 服务端、不做跨设备授权。
- 不向第三方开放曲库搜索、歌单写操作、用户资料。
- 不支持未安装的第三方（无「网页回调」形态）。

---

## 3. 术语

| 术语 | 含义 |
|---|---|
| Client | 已登记的第三方 App，由 `clientId` + 包名 + 签名指纹唯一确定 |
| Scope | 一项能力授权，共 4 种 |
| Code | 一次性授权码，32 字节随机，TTL 60s，绑定 client + scopes |
| 静默 scope | 无需 UI 确认即可续期的 scope：`genre.read` / `url.resolve` / `playback.control` |
| 敏感 scope | 必须每次前台确认：`account.token` |

---

## 4. 威胁模型与缓解

| # | 威胁 | 缓解措施 | 残余风险 |
|---|---|---|---|
| T1 | 恶意 App 冒用已注册 Client 的 `client_id` | ① `client_id` 必须与本机已安装包的包名、签名 SHA-256 同时匹配注册表；② 数据**只**通过 explicit intent 投递给该包，不投递给调用方给的任何地址 | 攻击者无法收到 code，故拿不到数据 |
| T2 | 自定义 scheme 被抢注劫持回跳 | 不使用 scheme 回跳。授权结果用 `Intent.setPackage()` 的 explicit intent 投递，系统只投给目标包 | 需目标包存在且签名一致 |
| T3 | 本机其他 App 扫描 loopback 端口窃取数据 | 端口随机（系统分配）、仅绑 `127.0.0.1`、必须持有效 code 才能交换、code 一次性且 60s 过期、单次交换后立即关服 | 无 code 时端口无意义 |
| T4 | code 重放 | 交换成功即从内存删除；过期清理；同一 code 第二次请求返回 401 | — |
| T5 | 令牌被静默窃取 | `account.token` 不进入静默白名单，每次请求强制前台确认页；确认页单独高亮令牌条目 | 用户主动同意后无法约束第三方用途 |
| T6 | 撤销后旧授权继续可用 | 每次请求都从存储重新读授权记录；撤销时删除记录 + 清空该 client 所有未使用 code + 关闭进行中的 loopback server | — |
| T7 | 恶意高频调用 | 每 client 每分钟最多 10 次 code 签发，超限返回 `rate_limited` | — |
| T8 | 日志泄露令牌 | 访问日志只记 `clientId / scopes / result / ts`，**不记录任何返回值** | — |
| T9 | 授权页诱导点击 | 「允许」「拒绝」同为次级样式，无主色实心按钮（规范 §6.8） | — |
| T10 | 用户误授权给山寨 App | 确认页展示 PackageManager 取到的真实应用名 + 图标 + 包名 + 签名指纹前 8 位 | 用户仍需自行判断是否信任该 App |

---

## 5. 总体架构

```
第三方 App
   │ ① startActivity(suchmusic://oauth/authorize?client_id&package&scopes&state&silent)
   ▼
MainActivity ──► DeepLinkService ──► ThirdPartyAuthService（唯一决策点）
                                        │
                    ┌───────────────────┼────────────────────┐
                    ▼                   ▼                    ▼
            ClientRegistry        AuthStore(SP)         DataProvider
         包名+签名白名单         授权记录/访问日志       genre / token / url / play
                    │                   │
                    └────────┬──────────┘
                             ▼
                    需要 UI？ ──是──► ThirdPartyAuthPage（确认页）
                             │否
                             ▼
                    CodeService（签发 code）
                             │
                    ┌────────┴─────────┐
                    ▼                  ▼
        LoopbackServer(127.0.0.1)   NativeBridge.sendCallback
        等待 POST /v1/exchange      explicit intent 投递 code+port+state
                    ▲                  │
                    └────── ② POST ────┘
                         第三方拿 code 换数据
```

**单一决策点原则**：所有 scope 判定、静默判定、限流、撤销检查只在 `ThirdPartyAuthService` 内完成，UI 与网络层不得自行放行。

---

## 6. 协议设计

### 6.1 拉起 URL

```
suchmusic://oauth/authorize
  ?client_id=<string>        必填，注册表主键
  &package=<string>          必填，调用方包名，必须与注册表一致
  &scopes=genre.read,url.resolve   必填，逗号分隔
  &state=<string>            必填，原样回传，防跨请求混淆
  &silent=1                  可选，请求静默续期
```

校验顺序（任一失败即中止，不签发 code）：
1. `client_id` 存在于注册表
2. `package` 与注册表一致，且该包已安装
3. 已安装包的签名 SHA-256 与注册表一致
4. `scopes` 均合法且非空
5. `state` 长度 1–128

### 6.2 Scope 定义

| Scope | 返回数据 | 可静默 | 说明 |
|---|---|---|---|
| `genre.read` | `{topGenres:[{tag,weight}], sampleSize, updatedAt}` | ✅ | 聚合 `GenreMetadataService.tagIndex`，归一化取前 10 |
| `url.resolve` | `{url, source, songId, resolvedAt}` | ✅ | 入参需带 `song` 对象（见 6.5） |
| `playback.control` | `{ok, action}` | ✅ | 仅 `play/pause/resume/next/previous` |
| `account.token` | `{platform, token, userId, nickname}` | ❌ | 每次前台确认；未登录返回 `not_logged_in` |

### 6.3 授权确认页

- 全屏 `ThirdPartyAuthPage`，不可跳过、不可点遮罩关闭，返回键等同「拒绝」。
- 结构：应用图标 + 应用名 + 包名 → 一句「请求访问以下内容」→ scope 列表（图标 + 标题 + 一句说明）→ 底部「拒绝」「允许」并排、同为次级样式。
- `account.token` 条目额外显示警示文案：「将把你的酷狗账号令牌交给该应用，令牌可用于代表你调用酷狗接口」。
- 底部固定一行小字：「授权后可随时在 设置 → 第三方授权 中撤销」。
- 拒绝：回传 `error=access_denied`，不写授权记录。

### 6.4 code 投递

授权通过后：

1. `CodeService.issue(clientId, scopes, package)` → `code`（32B base64url）、`port`（LoopbackServer 实际端口）
2. `NativeBridge.sendClientCallback(package, {code, port, state, client_id, scopes})`
   - Android 侧：`Intent("com.lightningteam.suchmusic.CLIENT_CALLBACK").setPackage(package)` + `putExtras`
   - `resolveActivity == null` → 返回 `no_callback_activity`，**不写授权记录**（避免用户同意后数据无处可去却留下授权）
3. 第三方 Activity 收到后，立即 `POST http://127.0.0.1:{port}/v1/exchange`

### 6.5 数据交换

```
POST /v1/exchange
Authorization: Bearer <code>
Content-Type: application/json

{"request": {"url.resolve": {"song": {...}}, "playback.control": {"action": "play", "song": {...}}}}
```

成功 200：

```json
{
  "client_id": "com.example.player",
  "scopes": ["genre.read", "url.resolve"],
  "issued_at": 1731600000,
  "data": {
    "genre.read": {"topGenres": [{"tag": "流行", "weight": 0.42}], "sampleSize": 128, "updatedAt": 1731599000},
    "url.resolve": {"url": "https://...", "source": "netease", "songId": "123", "resolvedAt": 1731600000}
  }
}
```

错误码：`invalid_code` / `code_expired` / `scope_not_granted` / `not_logged_in` / `resolve_failed` / `rate_limited` / `bad_request`，均返回 `{"error": "<code>", "message": "<中文说明>"}`。

约束：
- 只接受 `127.0.0.1` 来源，校验 `Host` 头为 `127.0.0.1:{port}`
- 请求体 ≤ 32KB
- 交换成功立即关服；60s 无请求自动关服
- `account.token` 的 code 必须带 `foreground_confirmed=true` 标记，否则拒绝返回令牌

### 6.6 静默续期

条件（全部满足才静默）：
1. 该 client 已有授权记录
2. 请求 scopes ⊆ 已授权 scopes
3. 请求 scopes 不含 `account.token`
4. 距上次同 client 静默调用 ≥ 5s（防抖）

满足 → 跳过 UI，直接 6.4 → 6.5，并投递系统通知：「{App 名} 读取了你的曲风画像」/「…获取了歌曲直链」/「…正在通过 SuchMusic 播放」。通知点击进入「设置 → 第三方授权」。

不满足 → 弹确认页，且只展示**新增或敏感**的 scope，已授权 scope 折叠为「已授权的 2 项」。

### 6.7 撤销

- 入口：设置 → 第三方授权 → 列表（应用名、已授权 scope、最近访问时间）
- 单项撤销 / 全部撤销
- 撤销动作：删记录 → 清该 client 未使用 code → 关 server → 写访问日志 `revoked`
- 撤销后同一 client 再调用必须重新走确认页

---

## 7. 数据模型

```dart
// lib/models/third_party_auth.dart
enum ThirdPartyScope { genreRead, accountToken, urlResolve, playbackControl }
// code: 'genre.read' | 'account.token' | 'url.resolve' | 'playback.control'

class ThirdPartyClient {
  final String clientId;
  final String packageName;
  final String signatureSha256; // 小写 hex
  final String displayName;     // 注册表里的名称，UI 以 PackageManager 结果优先
}

class ThirdPartyGrant {
  final String clientId;
  final String packageName;
  final Set<ThirdPartyScope> scopes;
  final int grantedAt;   // epoch seconds
  final int lastAccessAt;
  final int callCount;
}

class ThirdPartyAccessLog {
  final String clientId;
  final List<ThirdPartyScope> scopes;
  final String result;   // granted / denied / exchanged / revoked / error:<code>
  final int ts;
}
```

存储键：`third_party_grants_v1`、`third_party_access_log_v1`（最多 50 条，FIFO）。
存储介质：`shared_preferences`（与项目现有做法一致，不引入数据库）。

---

## 8. 接口契约

### 8.1 Dart 服务

```dart
class ThirdPartyAuthService {
  static final ThirdPartyAuthService instance = ...;

  /// 深链入口唯一入口；返回 null 表示已静默完成
  Future<AuthOutcome> handleAuthorizeRequest(Uri uri);

  Future<List<ThirdPartyGrant>> listGrants();
  Future<void> revoke(String clientId);
  Future<void> revokeAll();
  Future<List<ThirdPartyAccessLog>> recentLogs();
}

sealed class AuthOutcome {}
class AuthNeedsUi extends AuthOutcome { final AuthRequest request; }
class AuthCompleted extends AuthOutcome { final String clientId; }
class AuthFailed extends AuthOutcome { final String error; final String message; }
```

### 8.2 原生桥（MethodChannel `suchmusic/third_party`）

| 方法 | 入参 | 出参 |
|---|---|---|
| `getInstalledAppInfo` | `{package}` | `{installed, label, signatureSha256, versionName}` |
| `sendClientCallback` | `{package, extras}` | `{sent, reason?}` |
| `getLaunchUri` | — | `{uri}`，冷启动时的初始深链 |
| `getAppIcon` | `{package}` | `ByteArray?`，96×96 PNG（确认页展示真实图标；取不到为 null，UI 退回首字占位） |
| `showAccessNotice` | `{title, content}` | `bool`，走通道 `third_party_access`（`IMPORTANCE_DEFAULT`，`PendingIntent` 拉起 `MainActivity`） |

签名指纹取 `PackageManager.GET_SIGNING_CERTIFICATES`，对首个签名证书的 SHA-256 取小写 hex。多签名包取第一个并记录告警。

### 8.3 注册表

`lib/services/third_party/client_registry.dart` 内置 `const List<ThirdPartyClient> kRegisteredClients`。
接入新 Client = 往该数组加一条 + 发版。Debug 构建额外注入 `debug.suchmusic.probe`（包名同签名 debug key）用于自测，Release 构建不包含。

---

## 9. 时序

### 9.1 首次授权

```
Client → System → MainActivity(VIEW suchmusic://)
MainActivity → DeepLinkService.parse
DeepLinkService → AuthService.handleAuthorizeRequest
AuthService → Registry 校验 client_id/package/签名
AuthService → AuthStore 查是否已授权
AuthService → UI: AuthNeedsUi
UI(ThirdPartyAuthPage) → 用户点「允许」
UI → AuthService.grant(scopes)
AuthService → CodeService.issue
AuthService → LoopbackServer.start → port
AuthService → NativeBridge.sendClientCallback(code,port,state)
Client → POST 127.0.0.1:port/v1/exchange (Bearer code)
LoopbackServer → DataProvider 取数 → 200 JSON → 关服
```

### 9.2 静默续期

```
Client → MainActivity → AuthService
AuthService → 校验已授权 + scopes ⊆ grant + 无 account.token
AuthService → CodeService.issue → LoopbackServer → sendClientCallback
AuthService → NotificationService.notify("{App} 读取了你的曲风画像")
（无 UI）
```

### 9.3 撤销

```
Settings → ThirdPartyAuthListPage → 撤销
→ AuthStore.remove → CodeService.drop(clientId) → LoopbackServer.stop
→ 访问日志写 revoked → 列表刷新
```

---

## 10. 文件清单

| 文件 | 类型 | 说明 |
|---|---|---|
| `lib/models/third_party_auth.dart` | 新增 | Scope / Client / Grant / Log 模型 |
| `lib/services/third_party/client_registry.dart` | 新增 | 包名+签名白名单 |
| `lib/services/third_party/third_party_auth_service.dart` | 新增 | 唯一决策点 |
| `lib/services/third_party/auth_code_service.dart` | 新增 | code 签发/校验/清理 |
| `lib/services/third_party/loopback_server.dart` | 新增 | 127.0.0.1 单次交换服务 |
| `lib/services/third_party/third_party_data_provider.dart` | 新增 | 四类数据取数 |
| `lib/services/third_party/deep_link_service.dart` | 新增 | URI 解析与入口分发 |
| `lib/services/third_party/third_party_bridge.dart` | 新增 | MethodChannel 封装 |
| `lib/screens/third_party_auth_page.dart` | 新增 | 授权确认页 |
| `lib/screens/third_party_auth_list_page.dart` | 新增 | 授权管理/撤销页 |
| `lib/widgets/scope_tile.dart` | 新增 | 权限条目组件 |
| `lib/screens/settings_page.dart` | 改动 | 增加「第三方授权」入口 |
| `lib/main.dart` | 改动 | 冷启动深链分发 |
| `lib/widgets/update_checker.dart` | 改动 | 只显示本次版本段落 |
| `lib/services/update_service.dart` | 改动 | 增加 `changelogFor(version)` 解析 |
| `android/app/src/main/AndroidManifest.xml` | 改动 | 注册 `suchmusic` scheme |
| `android/app/src/main/kotlin/.../ThirdPartyBridge.kt` | 新增 | 签名校验 / explicit intent |
| `android/app/src/main/kotlin/.../MainActivity.kt` | 改动 | 转发深链与 newIntent |

测试：`test/third_party_auth_test.dart`、`test/third_party_loopback_test.dart`、`test/third_party_data_test.dart`、`test/changelog_section_test.dart`、`test/third_party_ui_test.dart`、`test/third_party_deeplink_test.dart`。

---

## 11. 任务拆解（S3）

| 模块 | 内容 | 依赖 | 验收 |
|---|---|---|---|
| **M1** | 更新弹窗只显示本次版本 | 无 | 单元测试：给定多版本 CHANGELOG，`changelogFor('1.4.1')` 只返回该段；UI 断言弹窗不含旧版本标题 |
| **M2** | 模型 + 存储 + 注册表 + 原生签名校验 | 无 | 假注册表能校验通过/失败；签名不符拒绝；SP 读写往返 |
| **M3** | 深链解析 + code 服务 + loopback 交换 | M2 | 端到端测试：签发 code → POST → 拿到 JSON → 二次 POST 401 → 过期 401 |
| **M4** | 授权确认页 + 管理页 + 设置入口 | M2/M3 | Widget 测试：首次强制出页、拒绝不落库、允许落库、列表可撤销、撤销后不可静默 |
| **M5** | 四类数据 provider | M3 | 曲风聚合、直链、代播、令牌（未登录报错）各一条测试 |
| **M6** | 通知 + 访问日志 + 端到端冒烟 | M4/M5 | 真机/模拟器跑一次完整授权→静默→撤销 |

---

## 12. ADR

### ADR-001 调用方身份采用包名 + 签名白名单

- **背景**：Android 隐式深链无法取得可信的调用方 UID，`getReferrer()` 可被伪造。
- **选项**：A 包名+签名白名单；B 开放申请+用户绑定；C 预共享密钥。
- **决定**：A。注册表内置，接入新 Client 需发版。
- **理由**：B 的首次绑定仍无法证明发起者身份，C 的密钥随客户端分发必然泄露。A 把信任根放在「系统安装校验 + 签名」上，不依赖调用方可控字段。
- **后果**：接入门槛高、需发版；换来的是冒名者拿不到 code，也就拿不到任何数据。

### ADR-002 数据通道：explicit intent 投递 code + loopback 单次交换

- **背景**：令牌属敏感数据，不能放 URL；scheme 回跳可被抢注。
- **选项**：A loopback HTTP；B scheme 回跳带参数；C 公共目录文件。
- **决定**：A，但 code **不**通过 scheme 投递，而是 `setPackage()` 的 explicit intent。
- **理由**：loopback 避免数据进系统日志；explicit intent 保证只有白名单包能收到 code；两者组合后，攻击者既收不到 code 也猜不到端口。
- **后果**：第三方需声明一个 exported Activity 接收回调；实现比 scheme 回跳复杂，但漏洞面最小。

### ADR-003 令牌不进入静默白名单

- **背景**：用户要求「静默传最新数据」。
- **决定**：`account.token` 每次前台确认，其余三项可静默。
- **理由**：令牌等价账号控制权，静默返回意味着第三方可在用户无感知下长期代表用户调用酷狗接口。曲风与直链是派生数据，泄露影响可控。
- **后果**：第三方拿令牌的体验多一步确认；这是刻意的摩擦。

### ADR-004 授权按 scope 长期有效 + 随时撤销

- **决定**：scope 粒度授权，长期有效，设置页可撤销，撤销即时生效。
- **理由**：与 OAuth 的 scope 模型一致，用户心智成本低；长期有效是静默续期成立的前提。
- **后果**：需保证每次请求都回查存储，不能缓存授权结果。

---

## 13. 残余风险与未决项

1. 第三方拿到数据后的二次分发无法约束，只能靠授权页告知。
2. `playback.control` 静默代播会在用户无操作时出声，属预期但可能打扰；M6 需验证通知可一键停止。
3. 多签名安装包目前取第一个证书，若第三方更换签名渠道包会被拒绝，需在接入文档中说明。
4. 未提供第三方接入 SDK 包，本期只交付协议文档 + 一个 debug 探针 Client。

---

## 14. 变更记录

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-11-14 | v1.0 | 初版：M1 更新弹窗修复 + 第三方授权接入架构 |
| 2026-11-14 | v1.1 | M4 落地：`ThirdPartyAuthPage` / `ThirdPartyAuthListPage` / 设置入口 / `main.dart` 接线；M6 落地：`showAccessNotice`（原生通知）+ `getAppIcon`（真实图标）；`AuthCodeService` 清理定时器改懒启动（构造不再创建 Timer） |
| 2026-11-14 | v1.2 | M1–M6 全部完成，567 测试通过；`account.token` 说明文案去重（说明行只讲「读什么」，警示行只讲「风险」）；版本 1.5.0+172 |
