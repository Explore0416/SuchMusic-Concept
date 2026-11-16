# SuchMusic概念版 · 网页（Web）授权接入协议参考

> 版本：1.5.4 起（1.5.3 首发，1.5.4 修复冷启动竞态与深链误判）。
> 适用对象：想从**浏览器网页**里唤醒 SuchMusic概念版并取回数据的开发者。
> Android 应用接入（intent + 回调 Activity）见开放平台《接入文档》，本文只写 Web 分支。
> 演示站点：<https://demo.lightning-team.top>（可作为参考实现）。

---

## 0. 一页话总结

```
你的网页 ──①suchmusic://oauth/authorize 深链──▶ SuchMusic概念版（弹确认页）
    │                                              │
    │                                     ②用户点「允许」
    │                                              │
    ◀──③Custom Tabs 回跳 redirect_uri#code&port&state──┘
    │
    ├─④校验 state、把 code_verifier 收好、立刻清掉 URL 片段
    │
    └─⑤fetch http://127.0.0.1:{port}/v1/exchange（带 code + code_verifier）
              │
              └─▶ 拿到 JSON 数据（曲风画像 / 歌曲直链 / 代播结果）
```

**四个硬性事实**：

1. **数据不经过任何服务器**。第 ⑤ 步是浏览器直连手机本机的回环端口，你的网站后端拿不到、也不需要这些数据。
2. **网页客户端强制 PKCE（S256）**。网页是公开客户端，没有可藏的密钥，必须用
   `code_challenge`/`code_verifier` 防授权码被截获后冒用。
3. **每次都要用户前台确认**。网页没有安装包签名做长期身份绑定，因此没有静默续期——
   不像 Android 客户端那样可以 `silent=1`。
4. **`code` 一次性、60 秒过期**。回跳后立刻换数据，换完即止，重放一律 401。

---

## 1. 注册一个 Web 应用

1. 登录[开放平台](https://open.lightning-team.top)→ 控制台 →「新建应用」。
2. **应用类型选「网页（Web）」**。此时表单不会要求包名与签名指纹，改为要求填写
   **回调地址（redirect_uri）**，每行一个，最多 10 个。
3. redirect_uri 规则（审核会逐条核对）：
   - 必须是 `https://` 完整地址（生产），调试可登记 `http://localhost` / `http://127.0.0.1`；
   - **回跳时逐字命中**登记值（含路径、不含查询串差异——查询串由你自行附加）；
   - 建议用专用回调路径，例如 `https://你的域名/callback`，不要用首页。
4. 勾选能力（scopes），写清用途说明，提交。审核通过后获得 `client_id`（形如 `sm_xxxxxxxxxxxxxxxx`）。
5. 应用信息出现在公开清单
   [`/api/v2/clients`](https://open.lightning-team.top/api/v2/clients)
   里，即代表接入端（SuchMusic概念版 1.5.3+）可以识别你了。

> **改名 / 改回调地址会触发重新审核**：安全相关字段（redirect_uris、scopes）变更必须重审；
> 仅名称变更也会回到待审队列（防止审核通过后偷换展示名钓鱼），管理员重新通过即可。

---

## 2. 唤起深链（网页版参数）

```
suchmusic://oauth/authorize?client_id={client_id}
    &scopes={逗号分隔}
    &state={随机串}
    &redirect_uri={登记过的 https 回调}
    &code_challenge={S256 挑战}
    &code_challenge_method=S256
```

| 参数 | 必填 | 约束 | 说明 |
|---|---|---|---|
| `client_id` | 是 | `sm_` 开头 | 平台分配的标识 |
| `scopes` | 是 | 逗号分隔，重复自动去重 | 只能申请登记过的 scopes 子集 |
| `state` | 是 | 1–128 字符随机 | 原样回传，必须校验，防 CSRF |
| `redirect_uri` | 是（Web） | **逐字命中**登记值 | 不匹配 → `invalid_redirect_uri` |
| `code_challenge` | 是（Web） | 43 字符 base64url | 见 §3 PKCE |
| `code_challenge_method` | 是（Web） | 只接受 `S256` | `plain` 一律拒绝 |
| `package` | **禁止**（Web） | — | 网页应用携带此参数直接 `invalid_request` |
| `silent` | **禁止**（Web） | — | 网页无静默续期，带了也不会生效 |

组装示例（浏览器侧）：

```js
const query = new URLSearchParams({
  client_id: 'sm_xxxxxxxxxxxxxxxx',
  scopes: 'genre.read,url.resolve',
  state: state,                       // 见 §3.3
  redirect_uri: 'https://你的域名/callback',
  code_challenge: challenge,          // 见 §3.2
  code_challenge_method: 'S256',
});
window.location.href = 'suchmusic://oauth/authorize?' + query.toString();
```

> 移动端浏览器里 `window.location.href = 'suchmusic://...'` 即可唤起。
> 微信 / QQ 等内置浏览器可能屏蔽自定义 scheme，需提示用户「用系统浏览器打开」。

---

## 3. PKCE（RFC 7636）详解

### 3.1 为什么必须做

授权码 `code` 会出现在**回跳 URL 的片段**里。恶意 App 若抢先注册了同样的
`redirect_uri`，或链路上有旁观者，都可能拿到 `code`。PKCE 的原理：
**`code` 只能配合发起者手里的 `code_verifier` 使用**，光有 code 换不到数据。

### 3.2 生成挑战（S256）

```js
function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// ① 生成 43–128 字符的 verifier（字符集 [A-Za-z0-9-._~]）
const bytes = crypto.getRandomValues(new Uint8Array(32));
const codeVerifier = base64url(bytes);           // 43 字符

// ② 计算挑战：BASE64URL(SHA256(ASCII(verifier)))
const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(codeVerifier));
const codeChallenge = base64url(new Uint8Array(digest));   // 43 字符
```

**测试向量**（RFC 7636 附录 B，可用于校验你的实现）：

```
verifier   = dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk
challenge  = E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM   (method = S256)
```

### 3.3 state 与 verifier 的存放

- `state` 与 `code_verifier` 放 `sessionStorage`（跟随标签页生命周期，比 `localStorage` 更收敛）；
- 回跳后**先校验 `state` 再用 `verifier`**，用完立即删除；
- 绝不放进 URL 查询串（会进服务器日志）。

---

## 4. 回跳协议（redirect_uri 片段）

用户点「允许」后，SuchMusic概念版用**系统浏览器（Custom Tabs）**打开：

```
https://你的域名/callback#code={一次性授权码}&port={本机端口}&state={原样回传}
        &client_id={sm_...}&scopes={本次实际授予的 scope 列表}
```

| 字段 | 说明 |
|---|---|
| `code` | 一次性授权码，**60 秒有效**，用一次即作废 |
| `port` | 手机本机回环服务端口（随机，不要写死），数据交换的目标端口 |
| `state` | 与发起时一致才可信；不一致立即中止并丢弃 |
| `client_id` | 回显，便于多应用共用回调页时分流 |
| `scopes` | **实际授予**的（可能少于申请的） |

**拿到片段后要立刻做三件事**：

```js
const raw = location.hash.slice(1);          // 注意是 hash（#），不是 search（?）
const params = new URLSearchParams(raw);
history.replaceState(null, '', location.pathname);   // ① 清掉 URL 里的 code
const state = sessionStorage.getItem('smo.state');   // ② 校验 state
if (params.get('state') !== state) { /* 中止 */ }
const verifier = sessionStorage.getItem('smo.verifier'); // ③ 取出 verifier
```

> **为什么用 `#` 片段而不是 `?` 查询**：片段不会被发送到任何 HTTP 服务器，
> `code` 因此不会进你的访问日志、CDN 日志、Referer 头。这是刻意设计。

用户点「拒绝」时**不会回跳**，你的页面无从得知；超时未操作同理。
因此发起页要给「没有唤起 App / 超时未返回」的兜底提示。

---

## 5. 浏览器取数（回环交换）

```js
const res = await fetch(`http://127.0.0.1:${port}/v1/exchange`, {
  method: 'POST',
  headers: {
    'Authorization': `Bearer ${code}`,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({
    code_verifier: verifier,      // Web 客户端必填
    request: {                    // 可选：按需指定要什么
      'url.resolve': { song: { id: '186016', source: 'netease', name: '东风破', artist: '周杰伦' } },
      'playback.control': { action: 'play', song: { id: '186016', source: 'netease' } },
    },
  }),
});
const payload = await res.json();
```

### 5.1 CORS 与私有网络访问（PNA）

SuchMusic概念版的回环服务**只对你登记的 Origin 回 CORS 头**（`access-control-allow-origin`
逐字比对 `Origin` 头）；其它来源一律 403 且不回 CORS 头，浏览器会拦截读取。

另外，Chrome 的 Private Network Access 要求「HTTPS 页面 → 本机 HTTP」的请求带
`Access-Control-Allow-Private-Network: true`，服务端已返回该头；预检（OPTIONS）形如：

```
OPTIONS /v1/exchange HTTP/1.1
Origin: https://你的域名
Access-Control-Request-Method: POST
Access-Control-Request-Headers: authorization, content-type

→ 204
  Access-Control-Allow-Origin: https://你的域名
  Access-Control-Allow-Methods: POST, OPTIONS
  Access-Control-Allow-Headers: authorization, content-type
  Access-Control-Allow-Private-Network: true
  Access-Control-Max-Age: 600
```

> **http://localhost 调试**：本地调试页是 http 源，同样需要把
> `http://localhost:端口`（含端口）登记进 redirect_uris / Origin 白名单。
> Origin 白名单取自登记的 redirect_uris 的 origin 部分。

### 5.2 请求 / 响应字段

**请求体**（≤32KB，可为空）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `code_verifier` | string | **Web 必填**；与唤起时的 challenge 配对（RFC 7636） |
| `request` | object | 可选；指定要取的数据，不给则返回本 code 覆盖的全部 scope |

**成功响应 200**：

```json
{
  "client_id": "sm_xxxxxxxxxxxxxxxx",
  "scopes": ["genre.read", "url.resolve"],
  "issued_at": 1731600000,
  "data": {
    "genre.read": {
      "topGenres": [
        { "tag": "流行", "weight": 0.42 },
        { "tag": "摇滚", "weight": 0.31 }
      ],
      "sampleSize": 128,
      "updatedAt": 1731599000
    },
    "url.resolve": {
      "url": "https://m801.music.126.net/.../song.mp3?auth=...",
      "source": "netease",
      "songId": "186016",
      "resolvedAt": 1731600000
    }
  }
}
```

各 scope 数据结构：

| scope | data 形状 | 备注 |
|---|---|---|
| `genre.read` | `{ topGenres[{tag,weight}], sampleSize, updatedAt }` | 不含歌名歌手，weight 归一化 |
| `url.resolve` | `{ url, source, songId, resolvedAt }` | `url` 是**带签名的临时直链**，勿外泄 |
| `playback.control` | `{ action, ok, songId? }` | action ∈ play/pause/resume/next/previous |
| `account.token` | `{ platform, token, userId, nickname }` | 仅 Android 客户端可申请（Web 禁止） |

### 5.3 交换层错误码（HTTP）

| HTTP | error | 含义 | 处理 |
|---|---|---|---|
| 401 | `invalid_code` / `code_expired` | code 无效 / 过期 / 已用过 | 重新走授权 |
| 401 | `pkce_required` | 缺 `code_verifier` | 修请求体 |
| 401 | `invalid_code` | verifier 与 challenge 不匹配 | 用发起时同一个 verifier |
| 403 | `scope_not_granted` | 请求了未授予的 scope | 只请求已授予范围 |
| 403 | （无 CORS 头） | Origin 不在白名单 | 用登记过的域名发起 |
| 400 | `bad_request` | 请求体非合法 JSON | 修请求体 |
| 400 | `resolve_failed` | 直链解析失败（版权/参数） | 检查 song 字段 |
| 400 | `not_logged_in` | 用户未登录酷狗 | 提示先在 App 内登录 |

约束：`code` 一次性；60 秒闲置自动关服；仅 `127.0.0.1` 监听；请求体 ≤32KB；
同一 client 每分钟最多 10 次授权签发（`rate_limited`）。

---

## 6. 最小完整示例

发起页（节选）：

```js
async function startAuth() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const verifier = base64url(bytes);
  const challenge = base64url(new Uint8Array(
    await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))));
  const state = base64url(crypto.getRandomValues(new Uint8Array(16)));
  sessionStorage.setItem('smo.verifier', verifier);
  sessionStorage.setItem('smo.state', state);
  location.href = 'suchmusic://oauth/authorize?' + new URLSearchParams({
    client_id: 'sm_xxxxxxxxxxxxxxxx',
    scopes: 'genre.read,url.resolve',
    state,
    redirect_uri: 'https://你的域名/callback',
    code_challenge: challenge,
    code_challenge_method: 'S256',
  }).toString();
}
```

回调页（节选）：

```js
const p = new URLSearchParams(location.hash.slice(1));
history.replaceState(null, '', location.pathname);
if (p.get('state') !== sessionStorage.getItem('smo.state')) throw new Error('state 不匹配');
const res = await fetch(`http://127.0.0.1:${p.get('port')}/v1/exchange`, {
  method: 'POST',
  headers: { 'Authorization': `Bearer ${p.get('code')}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ code_verifier: sessionStorage.getItem('smo.verifier') }),
});
sessionStorage.removeItem('smo.verifier');
sessionStorage.removeItem('smo.state');
const payload = await res.json();
// 渲染 payload.data …
```

---

## 7. 安全模型（Web 分支）

| 信任根 | 机制 |
|---|---|
| 「你是你登记的那个网站」 | `redirect_uri` 逐字命中 + 回跳走浏览器地址栏可见的 Custom Tabs |
| 「code 没被冒用」 | PKCE S256：code 只有配对 verifier 才能换数 |
| 「数据不外流」 | 回环交换只在手机本机；CORS 白名单限制读取方 |
| 「用户知情」 | 每次授权都强制前台确认页；无静默续期 |
| 「不可重放」 | code 一次性 + 60 秒过期；state 防跨请求混淆 |

开发者义务：

1. `code` / `code_verifier` / 直链 `url` / `token` 不得进日志、埋点、崩溃上报；
2. 直链是带签名的临时地址，不要转发到自己服务器或分享给他人；
3. 不要把 `code` 拼进任何出站链接；回跳后立即 `history.replaceState` 清片段；
4. `state` 必须校验；发现不一致按攻击处理（丢弃并记录）。

---

## 8. 调试速查

| 现象 | 诊断 |
|---|---|
| 点按钮没反应 / 手机没弹确认页 | 未安装 SuchMusic概念版，或版本低于 1.5.3（建议 1.5.4+）；或微信内置浏览器屏蔽 scheme，换系统浏览器 |
| 弹了 App 但显示「授权失败」 | App 会用 SnackBar 显示原因：`client_mismatch`＝未审核/参数不符；`invalid_redirect_uri`＝回调地址没逐字命中 |
| 回跳后 fetch 报 CORS | 页面 Origin 不在登记的 redirect_uris 的 origin 里；或用了 http 页面访问 https 回调 |
| fetch 报 `ERR_CONNECTION_REFUSED` | code 的 60 秒已过期、回环服务已关；重新发起授权 |
| 401 `invalid_code` | verifier 用了另一个标签页/刷新后丢失；state 存 sessionStorage 而非 cookie/localStorage |
| 手机浏览器打开但 App 是旧版 | 旧版把深链当歌曲「authorize」播放（1.5.4 已修复），升级 App |

**App 侧日志过滤**（adb logcat 或 Flutter debug）：

```
adb logcat | grep -i "ThirdParty\|suchmusic"
# [ThirdParty] 授权完成/授权失败/确认页已接管 …
```

---

## 9. 版本与兼容

| 组件 | 最低版本 | 说明 |
|---|---|---|
| SuchMusic概念版 App | 1.5.3（建议 1.5.4+） | 1.5.4 修复冷启动竞态（清单未就绪误判未登记）与深链被当歌曲播放 |
| 公开清单 | `/api/v2/clients` | 含 `app_type`/`redirect_uris`；v1 仅 Android 客户端，旧版 App 不受影响 |
| 演示站点 | <https://demo.lightning-team.top> | 完整参考实现（发起页 + 回调页，零存储） |
