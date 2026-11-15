# SuchMusic 第三方接入文档

面向 Android 开发者。读完本文，你的 App 可以通过 `suchmusic://` 拉起 SuchMusic，经用户授权后获取曲风画像、酷狗账号令牌、歌曲直链，或让 SuchMusic 代播。

> 适用版本：SuchMusic 1.5.0+（versionCode 172）
> 协议设计依据：`ARCHITECTURE.md` §6

---

## 1. 能力与权限

| scope | 能拿到什么 | 是否需要每次确认 |
|---|---|---|
| `genre.read` | 用户曲风画像：`topGenres[{tag, weight}]`、`sampleSize`、`updatedAt` | 否，已授权可静默 |
| `url.resolve` | 指定歌曲的可播放直链 | 否，已授权可静默 |
| `playback.control` | 让 SuchMusic 播放 / 暂停 / 切歌 | 否，已授权可静默 |
| `account.token` | 酷狗账号 `token` / `userId` / `nickname` | **是，每次都弹确认页** |

`account.token` 等价账号控制权，因此不进入静默白名单。这是刻意的设计，不是遗漏。

---

## 2. 接入前置：登记 Client

当前采用**包名 + 签名白名单**，每个应用都要经过审核。在开放平台注册并提交申请：

<https://open.lightning-team.top/register>

流程：注册账户 → 新建应用（填包名、签名指纹、申请的能力、用途说明）→ 管理员审核 → 通过后拿到 `client_id`，应用进入公开清单。

申请时提交：

| 字段 | 说明 |
|---|---|
| `clientId` | 你自定义的稳定标识，建议用包名 |
| `packageName` | 你的应用包名 |
| `signatureSha256` | 发布签名的 SHA-256，小写 hex |
| `displayName` | 展示给用户的应用名 |

取签名指纹：

```bash
apksigner verify --print-certs app-release.apk
# 取 "Signer #1 certificate SHA-256 digest"
```

登记后需要 SuchMusic 发一个新版本内置该条目。未登记的 `client_id` 一律返回 `client_mismatch`，且不会写入任何授权记录。

> Debug 构建内置探针 `client_id = debug.suchmusic.probe`，包名 `com.lightningteam.suchmusic.probe`，跳过签名校验，仅用于联调，Release 不包含。

---

## 3. 拉起授权

```kotlin
val uri = Uri.Builder()
    .scheme("suchmusic")
    .authority("oauth")
    .path("/authorize")
    .appendQueryParameter("client_id", "com.example.player")
    .appendQueryParameter("package", packageName)
    .appendQueryParameter("scopes", "genre.read,url.resolve")
    .appendQueryParameter("state", UUID.randomUUID().toString())
    .appendQueryParameter("silent", "1")   // 可选，请求静默续期
    .build()

startActivity(Intent(Intent.ACTION_VIEW, uri))
```

参数约束：

- `client_id` / `package` / `scopes` / `state` 必填
- `scopes` 逗号分隔，重复项自动去重
- `state` 长度 1–128，会原样回传，用于防跨请求混淆
- `silent=1` 只是**请求**静默，是否真的静默由 SuchMusic 判定（见 §6）

---

## 4. 接收授权结果

SuchMusic 不用 scheme 回跳（避免被抢注劫持），而是用 **explicit intent** 把结果投递给你的包：

```xml
<activity
    android:name=".SuchMusicCallbackActivity"
    android:exported="true">
    <intent-filter>
        <action android:name="com.lightningteam.suchmusic.CLIENT_CALLBACK" />
        <category android:name="android.intent.category.DEFAULT" />
    </intent-filter>
</activity>
```

```kotlin
class SuchMusicCallbackActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val code = intent.getStringExtra("code") ?: return finish()
        val port = intent.getIntExtra("port", 0)
        val state = intent.getStringExtra("state")
        val scopes = intent.getStringArrayExtra("scopes") ?: emptyArray()

        // 建议校验 state 与发起时一致
        // 拿到 code 后立刻换数据（code 60 秒过期，且只能使用一次）
        exchange(code, port, state)
        finish()
    }
}
```

**没有声明这个 Activity 的应用会被判定为 `no_callback_activity`，授权不会落库。** 这是为了避免「用户点了同意，数据却无处可去」。

---

## 5. 换取数据

```
POST http://127.0.0.1:{port}/v1/exchange
Authorization: Bearer {code}
Content-Type: application/json
```

请求体可为空（返回本枚 code 的全部 scope），也可指定：

```json
{
  "request": {
    "url.resolve": {
      "song": {
        "id": "123456",
        "source": "netease",
        "name": "东风破",
        "artist": "周杰伦"
      }
    },
    "playback.control": {
      "action": "play",
      "song": { "id": "123456", "source": "netease", "name": "东风破" }
    },
    "account.token": { "platform": "lite" }
  }
}
```

成功响应：

```json
{
  "client_id": "com.example.player",
  "scopes": ["genre.read", "url.resolve"],
  "issued_at": 1731600000,
  "data": {
    "genre.read": {
      "topGenres": [{"tag": "流行", "weight": 0.42}],
      "sampleSize": 128,
      "updatedAt": 1731599000
    },
    "url.resolve": {
      "url": "https://...",
      "source": "netease",
      "songId": "123456",
      "resolvedAt": 1731600000
    }
  }
}
```

约束：

- 服务只在 `127.0.0.1` 监听，端口由系统随机分配
- 一次 code 只能交换一次，成功即关服；60 秒不用自动关服
- 请求体上限 32KB
- `account.token` 若未经过前台确认，返回 403 `scope_not_granted`

---

## 6. 静默续期

再次拉起时带 `silent=1`。同时满足以下条件才会跳过确认页：

1. 该 `client_id` 已有授权记录
2. 请求的 scopes 是已授权 scopes 的子集
3. 请求不含 `account.token`
4. 距上次静默调用 ≥ 5 秒

静默完成时，SuchMusic 会发一条系统通知告知用户（「XXX 读取了你的曲风画像」等）。**不要试图绕过这条通知**，它是用户知情权的一部分。

不满足条件时，SuchMusic 会弹确认页，且只突出新增或敏感的 scope。

---

## 7. 错误码

| error | HTTP | 含义 | 你该怎么做 |
|---|---|---|---|
| `invalid_request` | 400 | 深链参数缺失或格式错 | 修正参数 |
| `client_mismatch` | — | 未登记 / 包名不符 / 签名不符 / 未安装 | 检查登记信息 |
| `invalid_scope` | 400 | scope 不合法 | 检查拼写 |
| `invalid_state` | 400 | state 为空或超 128 | 重新生成 |
| `rate_limited` | — | 同一 client 每分钟超过 10 次 | 退避重试 |
| `access_denied` | — | 用户拒绝 | 不要反复骚扰 |
| `no_callback_activity` | — | 未声明回调 Activity | 按 §4 声明 |
| `invalid_code` / `code_expired` | 401 | code 无效或已用 | 重新走授权 |
| `scope_not_granted` | 403 | 请求了未授权 scope，或令牌未经前台确认 | 重新申请该 scope |
| `not_logged_in` | 400 | 用户未登录酷狗 | 提示用户先登录 |
| `resolve_failed` | 400 | 直链解析失败（版权/参数错） | 检查 song 字段 |
| `bad_request` | 400 | 请求体不是合法 JSON 对象 | 修正 |

---

## 8. 用户撤销

用户可在 **设置 → 第三方授权** 中随时撤销某个应用，或一次性全部撤销。撤销后：

- 已授权 scope 立即失效
- 该 client 未使用的 code 全部作废
- 进行中的 loopback 服务立即关闭
- 你再调用必须重新走确认页

不要假设授权是永久的，每次静默请求都可能收到 `AuthNeedsUi` 对应的确认页。

---

## 9. 安全约束（请务必遵守）

1. **不要把 code 或 token 写进日志、崩溃上报、埋点。**
2. **不要把换到的 token 上传到自己的服务器**，除非你明确告知用户并取得同意。
3. **不要伪造 `package` 参数**，SuchMusic 会校验本机安装包与签名，伪造只会得到 `client_mismatch`。
4. **不要轮询**。需要最新数据时再拉起，频率受每分钟 10 次限制。
5. 回调 Activity 建议加 `android:exported="true"` 但不要导出其它敏感组件；`state` 必须校验。

---

## 10. 联调清单

- [ ] `adb shell am start -a android.intent.action.VIEW -d "suchmusic://oauth/authorize?client_id=debug.suchmusic.probe&package=com.lightningteam.suchmusic.probe&scopes=genre.read&state=test1"`
- [ ] 确认页出现，四项 scope 与申请一致
- [ ] 点「拒绝」→ 你的回调页不应被拉起
- [ ] 点「允许」→ 回调页收到 `code` / `port`
- [ ] `curl -X POST http://127.0.0.1:{port}/v1/exchange -H "Authorization: Bearer {code}"` 返回 200
- [ ] 同一 code 再请求一次 → 401
- [ ] 带 `silent=1` 再拉起 → 无确认页，收到系统通知
- [ ] 设置页撤销 → 再带 `silent=1` → 重新弹确认页
