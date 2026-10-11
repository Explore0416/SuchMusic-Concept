# SuchMusic 二改 · QA 验证报告（第 2 轮 · 回归验证）

| 项 | 内容 |
|---|---|
| 验证人 | QA Engineer（严过关） |
| 环境 | Flutter 3.47.7（`/opt/flutter`），无 Android 模拟器/真机 |
| 手段 | 独立复跑 + 逐行代码证据 + 注入式单测（假 resolver / 假 run） |
| 结论 | **路由 → NoOne**（8 项修复均已落地，全绿；遗留 2 条低风险观察项） |

## 一、真实复跑输出

```
$ flutter analyze lib test
Analyzing 2 items...
No issues found! (ran in 1.0s)

$ flutter test
00:01 +105: All tests passed!
```

（首轮 86 个用例 → 本轮加固后 **105 个**，全部通过。）

## 二、回归结论表（8 项修复逐条核实）

| # | 声称修复 | 结论 | 代码证据 |
|---|---|---|---|
| 高-1 | 新增 `resolveCounterpart` + 回退前解析对端歌曲 | **已修复** | `source_manager.dart:123-133`：回退前 `resolve ?? _netease.resolveCounterpart(song)`，用 `counterpart` 再调 `run(_netease, counterpart, true)`；解析不到→`return result`（`126-128`）。`netease_source.dart:67-86` 用「歌名+歌手」`_api.search`+`pickBestMatch`+`copyWith(source:netease)`，不再用酷狗 id。**返回语义一致**：能走到回退分支时 `result` 必为空（非空已在 `117` 提前 return），故失败时返回的始终是「空」，不会被当成回退成功。新文件 `sources/song_matcher.dart` 存在。 |
| 高-2 | `getSongUrl(strict)`；strict 拿不到真实 url 即 null | **已修复** | 抽象签名 `music_source.dart:31`；`netease_source.dart:49-50` 透传；`kugou_source.dart:172` 无兜底外链（无 url 即 `return null`）；`music_api_service.dart:225-227` strict 下 `return null`，非 strict 才返回 `outer/url`。**三实现一致**。调用点 `audio_player_service.dart:405-406 / 538-539` 均 `src.getSongUrl(s, strict: strict)` 正确传参。 |
| 中-3 | `_searchComplex` 补全参数；签名无 `&` 字典序 | **已修复** | `kugou_source.dart:111-131` 已含 `srcappid/bitrate/isfuzzy/inputtype/platform/userid/iscorrection/privilege_filter/filter/token`；`kugou_sign.dart:16-24` `buffer.write('$k=$v')`（无分隔符，key 已 sort）；`ARCH-二改.md:441` 措辞订正为「以 k=v 直接拼接（无分隔符）」，与实现一致。 |
| 中-4 | 平板 `width<900→2`，`>=900→3` | **已修复** | `responsive.dart:169-171`；`responsive_test.dart:178-196` 断言 600/719/840→2、900/1200/1600→3，绿。 |
| 中-5 | 首次失败置 `_focusDisabled` 熔断 | **已修复（含边界）** | `island_service.dart:88,98,111,117`。**边界结论**：`clearFocus` 亦被同一标志短路（`111`）——若「曾成功 applyFocus 后又失败」会残留焦点无法清除；但「首次即失败」无残留。判为低风险已知边界，建议（非阻塞）clearFocus 不参与短路。 |
| 低-6 | 删 `coverSize` 死分支 `b1PhonePortrait` | **已修复/等价** | `responsive.dart:72-104`：B1 在 `73-75` 提前 return（值不变 `width-50`）；`switch` 内 `default`（`96-100`）保留与 B1 同值仅作穷尽兜底，无 `b1PhonePortrait` case。430 竖屏=380 断言绿。 |
| 低-7 | 提取顶层 `parseLrc` | **已修复/行为一致** | `lyrics_parser.dart:21-47`；`audio_player_service.dart:20-21` re-export、`378` 调用 `parseLrc`。`lib` 内无残留 `_parseLrc`（仅注释提及）。`[mm:ss.xx]→xx0`、`[mm:ss.xxx]`、乱序升序、空/纯时间戳行过滤均断言绿。 |
| 低-8 | `dispose()` 补 `_fmModeController.close()` | **已修复** | `audio_player_service.dart:748-750`。 |

## 三、新增/修改的测试文件与用例数

| 文件 | 动作 | 用例数（本轮前→后） |
|---|---|---|
| `test/song_matcher_test.dart` | +6 边界（同名多结果/同名异歌手/括号/feat./空候选/无交集） | 8 → 14 |
| `test/lrc_parse_test.dart` | +5 边界（无时间戳/仅时间戳/重复/负数/超界分钟） | 8 → 13 |
| `test/source_manager_test.dart` | +4 四分支矩阵（主源成功不广播/回退成功/对端失败/strict 失败） | 10 → 14 |
| `test/responsive_test.dart` | +4 「430×932 基线护栏」（321.5/380/1.0/1.0） | 18 → 22 |

其余 `kugou_sign_test(10)`、`song_model_test(16)`、`notification_lyric_service_test(7)`、`widget_test(2+9 子例)` 未改，全绿。

## 四、新问题 / 越界核查

- **未越界（packages）**：与 pristine baseline 逐字节 diff，`packages/netease_music_api` **仅新增 `PROVENANCE.md`**，其余文件零差异；`play/api.dart:223,226,243` 的 `n` 补丁在、且为唯一相关改动。✔
- **docs/ 全为新增**（baseline 无 `docs/`）：无法用 diff 证明「仅 §4.6 改动」，但内容核对 `§4.6` 签名措辞已与实现一致（见中-3）。**本环境无法用版本管理验证该条**（如实标注）。
- **未使用代码**：`music_api_service.dart:786 getSongUrlForSong` 全仓无调用点（遗留 helper），非本轮引入、非阻断，列为低风险观察项。
- **新增文件无未使用 import/死代码**：`flutter analyze lib test` = No issues。
- **归源贯穿**：`play()` `audio_player_service.dart:393` 将 `_currentSong` 设为**原始歌曲**（source 仍为酷狗），回退用网易云 URL 播放但**不回写 source**。影响：后续复用该 song 会再次触发 `withFallback`→多一次对端搜索（轻微开销），**但结果正确**（每次按 `song.source` 路由+按需解析）。结论：非阻断观察项。

## 五、智能路由判定：**NoOne**

理由：8 项修复经代码证据 + 独立复跑 + 注入式测试逐条核实，**全部通过**；无源码 Bug，无测试 Bug。遗留 2 条（clearFocus 短路边界、`_currentSong.source` 未回写）经评估为**低风险、非阻断**观察项，不构成路由给 Engineer 的必要条件。

## 六、最终质量结论 + 仍未验证项

**已验证通过（本环境）**：8 项修复、回退/严格模式语义、LRC 解析一致性、响应式 430 基线护栏、签名黄金值、SongModel 兼容；`flutter analyze` 0 告警、`flutter test` 105/105 绿。

**本环境无法验证（需联网/真机，不得含糊）**：
1. 酷狗全部接口真实可用性（搜索/取 URL/VIP/歌词）——需联网 + 有效凭证；
2. 小米超级岛 / 通知副标题真机生效、`clearFocus` 残留焦点的真机表现；
3. `flutter build apk` / Kotlin 编译（沙箱无 Android 构建）；
4. 网易云/酷狗兜底 URL 是否真返回可播音频。
