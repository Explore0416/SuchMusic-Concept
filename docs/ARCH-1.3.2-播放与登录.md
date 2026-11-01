# 架构变更记录 · 1.3.2

> 本文档记录 1.3.2 的架构层变更与决策，作为 `docs/ARCH-二改.md` 之后的增量。
> 代码与文档同源：任何后续改动触及以下 6 条，必须同步回写本文。

## 1. 本地曲目回查：以 `localUri` 为准

**背景**：本地列表点歌后无任何反应，一首也放不出来，且没有任何提示。

**根因**：扫描结果 `Map<String, LocalTrack>` 的键是裸 uri
（`content://media/external/audio/media/42`），而 `SongModel.id` 是
`local:<uri>`（见 `LocalTrack.toSongModel`）。`_tracks[song.id]` 永远落空，
`_playableOf(null)` 返回 null，`_playSong` 直接 return。

**决定**：新增纯函数 `findTrackFor(tracks, song)`（`lib/services/local_music_service.dart`），
先按 `song.localUri` 查，再按 `song.id` 兜底。所有回查必须走它，不得直接 `tracks[song.id]`。

**约束**：`SongModel.id` 的前缀语义不得修改；若将来引入第二种本地 id 形态，
只能改 `findTrackFor`，不得在调用点散落判断。

**验证**：`test/local_track_lookup_test.dart`（5 条，含"错误用法必须查不到"的反向断言）。

## 2. 本地播放：双通道回退

**背景**：部分 ROM 对 MediaStore `content://` uri 的读取判定比标准更严，
ExoPlayer 抛 Security / FileNotFound，表现为"点了没反应 / Source error"。

**决定**：
- 扫描器对所有 MediaStore 条目都输出 `path`（真实文件路径），不再只给加密格式；
- `AudioPlayerService.play()` 先走原 uri（file → `setFilePath`，content → `setAudioSource`），
  失败且存在真实路径时，用 `file://` 再试一次；两次都失败才置 error 并给出提示。

**代价**：单曲播放最多多一次 15s 超时的等待，且只在失败分支发生。

**约束**：`playSongs`（批量）仍走 `ConcatenatingAudioSource`，不做逐条回退——
批量失败由页面层提示，不在此处吞掉。

## 3. 登录：单一弹层 + 音源分段

**背景**：同一动作出现三处入口（顶部"扫码登录"只认网易云、"音源账号"里网易云一行、
酷狗一行），酷狗用户必须先猜入口。

**决定**：
- 新增 `lib/widgets/login_sheet.dart`：`showLoginSheet(context, ...)` 底部弹层，
  顶部 `LoginSource` 分段（网易云 / 酷狗），内容区分别是 `NeteaseQrLoginBody`
  与 `KugouLoginBody`；
- 「我的」页删除「音源账号」区块与顶部齿轮，登录入口收敛为**身份卡整卡点击**；
- 身份卡副标题显示已连接音源（`_connectedSources()`）。

**约束**：`KugouLoginBody` 内部仍按 appid 分别授权（概念版 3116 / 原版 1005），
服务端不提供跨 appid 凭证兑换，不得合并成"一次扫码登录两个平台"。

**删除**：`lib/widgets/kugou_account_sheet.dart`（唯一入口已被统一弹层取代）。

## 4. 定时关闭：状态放在播放服务层

**决定**：`AudioPlayerService` 持有 `_sleepTimer / _sleepDeadline`，
对外暴露 `startSleepTimer / cancelSleepTimer / sleepRemaining / hasSleepTimer`。
播放页只做展示与选择，每秒刷新仅在有定时时触发 `setState`。

**理由**：放在页面 State 里会随页面销毁而失效，用户退出播放页后定时应当继续。

## 5. 下载落盘：公共目录优先，失败回退

**决定**：`SongDownloadService` 取址复用 `SourceManager().withFallback(..., strict)`
（与播放同一条链路，「能播就能下」）。落盘顺序：
1. `/storage/emulated/0/Music/SuchMusic/`（写探针文件确认可写）；
2. 失败则回退 `getExternalStorageDirectory()/SuchMusic/`；
3. 两者都失败返回明确错误文案。

**约束**：文件名清洗掉 `\/:*?"<>|` 并折叠空白；下载结果小于 32KB 视为失败并删除
（CDN 错误页不是音频）。

## 6. 返回动效：启用系统预测性返回

**决定**：
- `AndroidManifest.xml` application 节点加 `android:enableOnBackInvokedCallback="true"`；
- `AppTheme.light()` 的 `pageTransitionsTheme` 对 Android 使用
  `PredictiveBackPageTransitionsBuilder`。

**已知边界**：`fadeSlideRoute`（自定义 `PageRouteBuilder`）自带 transitionsBuilder，
不参与 theme 的预测性返回动画；需要缩放预览的页面请用 `MaterialPageRoute`。

## 附：字号与组件约束（沿用 1.3.0）

- 字号四档：28 / 20 / 15 / 12，禁止 10 / 11 / 11.5 / 13 / 14；
- 发丝线 0.7px；卡片圆角 20，行内 14，弹层顶部 28；
- `AppTag` 的文本已改为 `Flexible + ellipsis`，可在限宽（如播放页顶栏 96）内安全省略。
