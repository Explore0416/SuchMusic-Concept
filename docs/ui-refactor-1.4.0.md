# SuchMusic 1.4.0 UI 重构规格

> 依据：用户 2026-11-09 的 7 条界面评审意见 + 《综合型界面设计规范》
> 基线：`lib/theme/app_theme.dart` 已定义完整令牌，本次不新增颜色，只收敛用法。

## 0 全局基线（不得违反）

| 项 | 约束 |
|---|---|
| 画布 / 卡面 | `AppColors.canvas` #F7F7F5 / `AppColors.surface` #FFF |
| 主文字 | `AppColors.ink` #15171C，永远不用纯黑 |
| 强调 | `AppColors.brand` #2F5BFF，**只**用于选中态、进度填充、主 CTA 文字 |
| 字号 | 只有 28 / 20 / 15 / 12 四档，层级靠字重与灰阶 |
| 圆角 | 行 14 / 卡 20 / 英雄 26 / 胶囊 999；嵌套满足 `R_inner = R_outer - padding` |
| 图标 | 统一 Material Icons **Rounded**（`*_rounded`），线宽风格一致；仅「选中态」允许 filled |
| 热区 | ≥ 44×44 |
| 文案 | 禁止中点「·」；禁止「图标 + 主文字 + 说明」三件套解释同一件事 |

## 1 全局播放控制（意见 1）

**现状**：`lib/widgets/app_bottom_dock.dart` 的 `MiniPlayerCard` 高 60，进度条仅 2px 且不可拖，无上下曲按钮，只靠左右滑动手势。

**改法**：

1. 卡片高 60 → **76**，封面 44 → **48**，内圆角 12 → **14**（20 − 6 = 14，保持同心）
2. 进度条 2 → **3**，并包一层 **20px 高的透明拖拽热区**，接 `onSeek(double)`；已播部分 `AppColors.brand`，轨道 `surfaceMuted`
3. 行内控件自左至右：封面 / 歌名+艺人 / **上一首 34** / **播放键 40（墨色实心圆）** / **下一首 34**
   - 上一首、下一首图标 20，颜色 `inkSecondary`，热区各 44
   - 播放键保持现有「全卡唯一高对比元素」的地位
4. 投影由 `AppShadow.card` 升级为 `AppShadow.dock`，边框保持 0.7px `hairline`
5. `onSwipeNext` / `onSwipePrevious` 手势保留，与按钮并存
6. `AppLayout.miniPlayerHeight` 由 60 改 76，`bottomInsetWithPlayer` 同步 +16（168 → 184）
7. 窄屏（< 360）隐藏封面以保证文字不被压成两个字

**验收**：进度条能拖、能看见；三个按钮点得中；卡片在列表上方明显浮起。

## 2 双音源卖点（意见 2）

**现状**：`_SourceDot()` 只是首页日期旁一个 6px 小圆点，用户完全看不出「支持两个音源」是核心能力。

**改法**：

1. 新建 `lib/widgets/source_switcher.dart`：两个胶囊并排
   - 选中：`ink` 实心底 + 白字 + 12px 600
   - 未选中：`surfaceMuted` 底 + `inkSecondary` 字
   - 每个胶囊 高 32、左右 padding 14、圆角 999、间距 8
   - 胶囊前 6px 状态点：已登录 `brand`，未登录 `inkDisabled`
2. 首页 `_buildHeader()` 日期行下方的 `_SourceDot` **删除**，改为 `SourceSwitcher`，位置在 header 与搜索框之间，左右 20 边距
3. 点击切换调用既有音源切换逻辑（沿用 `SourceManager` 现有 API，不新造状态）
4. 「我的」页身份卡下方加一行双音源登录态：两个「点 + 名称」，已登录 `ink`，未登录 `inkTertiary`，12px

**验收**：一眼能看出这是双音源 App，且能直接切。

## 3 颜色与图标收敛（意见 3）

| 位置 | 现状 | 改为 |
|---|---|---|
| `profile_page.dart` 身份卡 | 渐变 `[0xFFF0F3FF, 0xFFFFFFFF]`（大面积冷蓝） | `AppColors.surface` 纯白 + 0.7px `hairline`，靠头像与字重立层级 |
| `library_page.dart:122` 喜欢卡 | `AppColors.rose` 面积过大 | 图标保留 `rose`，底色改 `AppColors.surface` |
| `local_music_view.dart` 骨架屏 | 硬编码 `0xFFE9E9E9` / `0xFFF8F8F8` | 改用 `surfaceMuted` / `surface` 派生 |
| 全局注释文字 | 灰 / 蓝 / 绿混用 | 只允许 `inkSecondary`（正文级辅助）与 `inkTertiary`（占位级） |
| `success` / `warning` / `danger` | 有用于普通说明的情况 | **只**用于真实状态（成功/警告/错误），普通说明一律灰阶 |
| 图标 | `_outlined` 与 `_rounded` 混用 | 全部 `_rounded`；仅底部导航选中态用 filled |

**验收**：截任一页面，除品牌蓝与红心外不应出现第三种彩色。

## 4 搜索可见性（意见 4）

**现状**：首页只有 header 右上角一个放大镜图标按钮，搜索页搜索框随内容一起滚动。

**改法**：

1. 首页 header 下常驻**搜索框**（不是按钮）：
   - 高 44，`surfaceMuted` 底，圆角 14，左 18px 放大镜 `inkTertiary`，文案「搜索歌曲、歌手、歌单」`inkTertiary` 15px
   - 整框可点，跳 `SearchPage`
   - header 右上角放大镜按钮删除，右侧留给「设置」或空
2. 搜索页：搜索框固定在顶部（`Column` 包裹，结果区独立滚动），滚动时不下移
3. 搜索页输入框获焦即弹键盘，取消按钮与输入框同一行，高 44

**验收**：任何页面滚动时搜索入口都在；进搜索页不用先找输入框。

## 5 文案瘦身（意见 5）

**规则**：一个列表项 = 图标 + 主文字。辅助说明只在「高风险 / 空状态 / 格式示例」三种情况保留。

逐处清理（以实际代码为准，逐条核对）：

- 「我的」页所有 `subtitle` / 说明行删除
- 「设置」页每个 `ListTile.subtitle` 删除，仅保留分组标题
- 首页三个 rail 的 `subtitle`（「根据本机播放记录挑选」「每天更新，为你挑 12 首」）删除
- 本地音乐页 header subtitle 改为只显示数量（`12 首`），去掉「全部保存在本机」
- 关于页、更新页的长段落不在本次范围

**验收**：设置页一屏能看到的分组项比现在多 5 条以上。

## 6 首页编排差异化（意见 6）

**现状**：猜你想听 / 每日推荐 / 热歌推荐三个区块都调用 `_buildSongRail`，同一套横向卡片，节奏完全一致，且区块间距仅 24。

**改法**：三种不同编排，密度递增。

1. **猜你想听** → 横向大卡 rail
   - 卡宽 148，封面 148×148 圆角 20，歌名 15/2 行，艺人 12
   - 卡间 12，左右 20
2. **每日推荐** → 两列网格
   - 一行 2 个，封面正方形，圆角 16，歌名 15/1 行，艺人 12
   - 列间距 12，行间距 20
   - 只展示前 6 首，右上角「全部」保留
3. **热歌推荐** → 紧凑排行列表
   - 前 5 首，行高 56，左侧 28 宽序号（01–05，`inkTertiary` 12px 600）
   - 封面 40 圆角 10，歌名 15/1 行，艺人 12
   - 行间 0.7px `hairline`（缩进 68）
4. 区块间距 24 → **36**；区块标题与内容间距 12 → 16
5. `_buildRankingRail` 与 `_buildPlaylistSquare` 保持现状，但间距同步改 36

**验收**：三个区块形状明显不同，一屏内不再像复制粘贴。

## 7 本地列表可点性（意见 7）

**现状**：`local_music_view.dart` 列表行直接铺在 canvas 上，无底色、无分割，和背景糊在一起。

**改法**：

1. 列表整体包一层 `surface` 容器：圆角 20、0.7px `hairline`、左右 20 边距
2. 行高 60，行间 0.7px `hairline`（左侧缩进 68，与封面右缘对齐）
3. 按下态 `surfaceMuted`（`InkWell` + `Material`，不能只在 `GestureDetector` 上）
4. 当前播放行：左侧 3×24 竖条 `brand` + 歌名 `brand` + 艺人 `inkSecondary`
5. 每行右侧「更多」按钮 `inkTertiary`，热区 44
6. 空状态：48px 图标 `inkDisabled` + 一句「还没有扫描到音频」+ 主按钮「扫描本机」

**验收**：列表与背景有明确边界；手指落下有反馈；正在播的那行一眼可见。

## 8 交付要求

- 只改 UI 层：`lib/screens/*`、`lib/widgets/*`、必要时 `lib/theme/app_theme.dart`；**不得**动 `lib/services/**` 的业务逻辑
- 不新增第三方依赖
- `flutter analyze` 零 error；既有测试全绿
- 新增测试：`test/ui_refactor_1_4_0_test.dart`
  - MiniPlayerCard：进度可拖、三个按钮各自回调、窄屏隐藏封面
  - SourceSwitcher：选中态切换、点击回调
  - 首页：三个区块使用不同组件类型
  - 本地列表：当前行高亮、空状态存在
- 版本号 1.4.0（versionCode 140）
