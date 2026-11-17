// 横屏播放页形态锁定。
//
// 横屏是**独立形态**，不照搬竖屏：
//
// ```text
// ┌──────────────────────────────────────────────┐
// │  ⌄         正在播放              音源   音效  │
// │  ┌────────┐   ○ 上一句歌词                     │
// │  │        │   ● 当前句（高亮）                 │
// │  └────────┘   ○ 下一句歌词                     │
// │    歌名 ♡     ○ ……（可滚动）                   │
// │  ──────●──────────────                        │
// │  ⟳   ⏮   ▶   ⏭   ☰                          │
// │  ⬇   ↗   ⏱   ⋯  （只有图标、无文字、贴左栏）    │
// └──────────────────────────────────────────────┘
// ```
//
// 与竖屏的三处刻意差异（用户明确要求）：
//  1. 歌词常驻右半屏多行滚动 —— 不是「点封面才出现」；
//  2. 封面是静态图，**点击没有任何反应**；
//  3. 下载 / 分享 / 定时 / 更多 收在左栏下方左对齐，**纯图标不带文字**。
//
// 本文件锁定：
//  1. 断点判定（最短边定形态 + 方向定布局）；
//  2. 6 个横屏尺寸：无 overflow、四入口在屏内、收藏/播放列表在屏内；
//  3. 横屏右栏常驻 FullLyricDisplay，左栏不再有单行 LyricDisplay（不重复）；
//  4. 点封面无反应：封面尺寸、进度条位置、歌词面板全部不变；
//  5. 四入口只占左半屏、贴左、且不渲染任何文字；
//  6. 竖屏 390×844 四入口带文字且仍在屏内（防止把竖屏改坏）。
//
// 音频通道：`PlayerPage` 依赖 just_audio / audio_service 单例，纯 Dart 测试里
// 平台通道缺失由服务内部 try/catch 吞掉；收藏 / 动作行需要一首当前歌曲才有
// 回调，这里用本地伪曲目 `play()`（只同步置上 currentSong，不触网）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netease_music_api/netease_music_api.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/screens/player_page.dart';
import 'package:such_music/services/audio_player_service.dart';
import 'package:such_music/utils/responsive.dart';

/// 测试用路径提供者：网易云 SDK 的 cookie / 数据目录指到临时目录，
/// 避开 path_provider 插件（widget test 里没有平台实现）。
class _TempPathProvider extends PathProvider {
  _TempPathProvider(this.root);

  final String root;

  @override
  Future<void> init() async {}

  @override
  String getCookieSavedPath() => '$root/.cookies/';

  @override
  String getDataSavedPath() => '$root/.data/';
}

/// 竖屏四个动作入口的文案（与 `_buildActionRow` 保持一致；横屏已改纯图标）
const List<String> _actionLabels = ['下载', '分享', '定时', '更多'];

/// 横屏四个动作入口的图标：横屏不带文字，只能按图标定位。
/// 定时未生效时是 `timer_outlined`（生效后是实心 `timer_rounded`）。
const List<IconData> _actionIcons = [
  Icons.download_rounded,
  Icons.ios_share_rounded,
  Icons.timer_outlined,
  Icons.more_horiz_rounded,
];

/// 本地伪曲目：路径不存在，play() 只把 currentSong 同步置上后静默失败。
const SongModel _probeSong = SongModel(
  id: 'landscape-parity-probe-1',
  name: '东风破',
  artist: '周杰伦',
  album: '叶惠美',
  duration: 300000,
  source: SongSource.local,
  localUri: 'file:///tmp/suchmusic-parity-nonexistent.mp3',
);

const List<Size> _landscapeSizes = <Size>[
  Size(568, 320), // 窄横屏：tiny 档，无封面
  Size(640, 360), // 手机横屏主场景下沿：compact 档
  Size(720, 480), // 手机横屏主场景：compact 档
  Size(800, 600), // 小平板横屏：full 档
  Size(1024, 600),
  Size(1280, 720),
];

/// 有封面的尺寸（tiny 档 <240 可用高会主动放弃封面）
const List<Size> _landscapeWithCover = <Size>[
  Size(640, 360),
  Size(720, 480),
  Size(800, 600),
  Size(1024, 600),
  Size(1280, 720),
];

void _useSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 直接 pump 真实 [PlayerPage]（横屏走 `_buildSplitBody`）。
Future<void> _pumpPlayer(WidgetTester tester, Size size) async {
  _useSize(tester, size);
  // play() 在首个 await 之前就同步写好 currentSong，故无需 await
  // ignore: discarded_futures
  AudioPlayerService().play(_probeSong);
  await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 收尾：卸载播放页并把假时钟推过 play() 内部的 10 秒超时，
/// 否则测试收尾会因「A Timer is still pending」误报失败（不是业务问题）。
Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 11));
  await tester.pump(const Duration(seconds: 1));
}

/// 动作按钮的点击热区（最近的 GestureDetector 祖先）
Finder _actionHitArea(String label) => find
    .ancestor(of: find.text(label), matching: find.byType(GestureDetector))
    .first;

/// 横屏动作按钮的点击热区（按图标定位，横屏不渲染文字）
Finder _actionHitAreaByIcon(IconData icon) => find
    .ancestor(of: find.byIcon(icon), matching: find.byType(GestureDetector))
    .first;

/// 收藏按钮：`_LikeButton` 用 `Icons.favorite(_border)`（非 rounded 变体），
/// 两种状态都算命中。
final Finder _likeIcon = find.byWidgetPredicate(
  (w) =>
      w is Icon &&
      (w.icon == Icons.favorite || w.icon == Icons.favorite_border),
);

/// 播放列表入口：`assets/images/svg/Playlist_Alternate.svg` 对应的 SvgPicture。
final Finder _playlistEntry = find.byWidgetPredicate(
  (w) =>
      w is SvgPicture &&
      w.bytesLoader is SvgAssetLoader &&
      (w.bytesLoader as SvgAssetLoader).assetName ==
          'assets/images/svg/Playlist_Alternate.svg',
);

/// 横屏封面：分栏左栏里唯一用 [AspectRatio] 撑正方形的元素。
final Finder _landscapeCover = find.byType(AspectRatio);

/// 断言某个 Finder 命中且**真的在屏内**（存在 ≠ 可见）。
void _expectOnScreen(
  WidgetTester tester,
  Finder finder,
  Size size,
  String what, {
  bool allowMultiple = false,
}) {
  if (allowMultiple) {
    expect(finder, findsWidgets, reason: '$what 应至少命中一个 widget');
  } else {
    expect(finder, findsOneWidget, reason: '$what 应命中一个 widget');
  }
  final rect = tester.getRect(finder);
  expect(rect.top, greaterThanOrEqualTo(0), reason: '$what 顶部被挤出屏幕');
  expect(
    rect.bottom,
    lessThanOrEqualTo(size.height),
    reason: '$what 底部超出屏高（bottom=${rect.bottom} > ${size.height}）',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('suchmusic_parity_test');
    await NeteaseMusicApi.init(provider: _TempPathProvider(dir.path));
  });

  group('断点判定：最短边定形态 + 方向定布局', () {
    test('568×320 → B2（窄横屏不得判成手机竖屏）', () {
      expect(
        Responsive.of(const Size(568, 320)),
        AppBreakpoint.b2PhoneLandscape,
      );
      expect(
        Responsive.isPlayerSplit(Responsive.of(const Size(568, 320))),
        isTrue,
      );
    });

    test('800×600 → B4（平板横屏不得判成平板竖屏）', () {
      expect(
        Responsive.of(const Size(800, 600)),
        AppBreakpoint.b4TabletLandscape,
      );
      expect(Responsive.isPlayerSplit(AppBreakpoint.b4TabletLandscape), isTrue);
    });

    test('800×1280 → B3（平板竖屏语义不变）', () {
      expect(
        Responsive.of(const Size(800, 1280)),
        AppBreakpoint.b3TabletPortrait,
      );
    });

    test('390×844 → B1（手机竖屏语义不变）', () {
      expect(
        Responsive.of(const Size(390, 844)),
        AppBreakpoint.b1PhonePortrait,
      );
    });

    test('1280×800 → B5（≥1200 宽横屏）', () {
      expect(Responsive.of(const Size(1280, 800)), AppBreakpoint.b5UltraWide);
    });
  });

  group('横屏：四入口（纯图标、贴左栏）/ 收藏 / 播放列表都在屏内', () {
    for (final size in _landscapeSizes) {
      testWidgets('${size.width.toInt()}×${size.height.toInt()} 无溢出且入口在屏内', (
        tester,
      ) async {
        await _pumpPlayer(tester, size);

        expect(tester.takeException(), isNull, reason: '不应出现 overflow');

        for (var i = 0; i < _actionIcons.length; i++) {
          final icon = _actionIcons[i];
          final what = '「${_actionLabels[i]}」入口（${size.width.toInt()}×${size.height.toInt()}）';
          expect(
            find.byIcon(icon),
            findsOneWidget,
            reason: '$what 缺少图标',
          );
          _expectOnScreen(tester, _actionHitAreaByIcon(icon), size, what);
        }

        // 纯图标：横屏不允许出现任何动作文案
        for (final label in _actionLabels) {
          expect(
            find.text(label),
            findsNothing,
            reason: '横屏底部入口不应带文字「$label」',
          );
        }

        // 贴左栏：整行落在左半屏，且第一个热区紧贴左侧（不是居中或横跨整屏）
        final first = tester.getRect(
          _actionHitAreaByIcon(_actionIcons.first),
        );
        final last = tester.getRect(_actionHitAreaByIcon(_actionIcons.last));
        expect(
          last.right,
          lessThanOrEqualTo(size.width * 0.5),
          reason:
              '动作行应只占左栏（last.right=${last.right}，屏宽 ${size.width}）',
        );
        expect(
          first.left,
          lessThan(size.width * 0.08),
          reason: '动作行应贴左边（first.left=${first.left}）',
        );

        _expectOnScreen(tester, _likeIcon, size, '收藏按钮');
        _expectOnScreen(tester, _playlistEntry, size, '播放列表入口');

        await _drain(tester);
      });
    }
  });

  group('横屏：右半屏常驻歌词，左栏不重复', () {
    for (final size in _landscapeSizes) {
      testWidgets('${size.width.toInt()}×${size.height.toInt()} 有且只有一份多行歌词', (
        tester,
      ) async {
        await _pumpPlayer(tester, size);

        expect(
          find.byType(FullLyricDisplay),
          findsOneWidget,
          reason: '横屏右栏应常驻多行歌词面板',
        );
        expect(
          find.byType(LyricDisplay),
          findsNothing,
          reason: '左栏不应再挂单行歌词（会与右栏重复）',
        );

        // 歌词面板真的在右半屏
        final lyricRect = tester.getRect(find.byType(FullLyricDisplay));
        expect(
          lyricRect.left,
          greaterThan(size.width * 0.45),
          reason: '歌词面板应落在右半屏（left=${lyricRect.left}）',
        );
        expect(lyricRect.bottom, lessThanOrEqualTo(size.height));

        await _drain(tester);
      });
    }
  });

  group('横屏：点封面没有任何反应', () {
    for (final size in _landscapeWithCover) {
      testWidgets('${size.width.toInt()}×${size.height.toInt()} 点击后布局不变', (
        tester,
      ) async {
        await _pumpPlayer(tester, size);

        expect(
          _landscapeCover,
          findsOneWidget,
          reason: '分栏左栏应只有封面用 AspectRatio 撑正方形',
        );
        final beforeRect = tester.getRect(_landscapeCover);
        final beforeProgress = tester.getTopLeft(find.byType(ProgressBar));
        final beforeLyricRect = tester.getRect(find.byType(FullLyricDisplay));

        // 封面没有手势：点在正中间，命中测试落空即可
        await tester.tap(_landscapeCover, warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          tester.getRect(_landscapeCover),
          beforeRect,
          reason: '点封面后封面尺寸/位置不得变化（横屏封面是静态图）',
        );
        expect(
          tester.getTopLeft(find.byType(ProgressBar)),
          beforeProgress,
          reason: '点封面后进度条位置不得变化',
        );
        expect(
          tester.getRect(find.byType(FullLyricDisplay)),
          beforeLyricRect,
          reason: '点封面后歌词面板不得变化',
        );
        expect(find.byType(FullLyricDisplay), findsOneWidget);
        expect(tester.takeException(), isNull);

        await _drain(tester);
      });
    }

    testWidgets('568×320（tiny 档）不显示封面，但功能一个不少', (tester) async {
      await _pumpPlayer(tester, const Size(568, 320));

      expect(
        _landscapeCover,
        findsNothing,
        reason: '可用高不足 240 时主动放弃封面，把空间留给控制与四入口',
      );
      for (var i = 0; i < _actionIcons.length; i++) {
        _expectOnScreen(
          tester,
          _actionHitAreaByIcon(_actionIcons[i]),
          const Size(568, 320),
          '568×320「${_actionLabels[i]}」入口',
        );
      }
      expect(tester.takeException(), isNull);

      await _drain(tester);
    });
  });

  group('竖屏回归', () {
    testWidgets('390×844 四入口 / 收藏 / 播放列表仍在屏内，且默认无大歌词', (tester) async {
      await _pumpPlayer(tester, const Size(390, 844));

      for (final label in _actionLabels) {
        expect(find.text(label), findsOneWidget, reason: '竖屏缺少「$label」入口');
        _expectOnScreen(
          tester,
          _actionHitArea(label),
          const Size(390, 844),
          '竖屏「$label」入口',
        );
      }
      _expectOnScreen(
        tester,
        _likeIcon.first,
        const Size(390, 844),
        '竖屏收藏按钮',
        allowMultiple: true,
      );
      _expectOnScreen(tester, _playlistEntry, const Size(390, 844), '竖屏播放列表入口');
      // 竖屏保持原语义：点卡片才展开大歌词，默认不铺
      expect(find.byType(FullLyricDisplay), findsNothing);
      expect(tester.takeException(), isNull);

      await _drain(tester);
    });
  });
}
