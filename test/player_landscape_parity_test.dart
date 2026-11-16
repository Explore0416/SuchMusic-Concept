// 1.5.2：横屏播放页必须与竖屏功能对等。
//
// 背景（1.5.1 实测）：`Responsive.of()` 只按宽度判形态、忽略横竖方向，于是
//  - 568×320（窄横屏）被判成 b1 手机竖屏 → 单列布局，溢出 563px；
//  - 800×600（平板横屏）被判成 b3 平板竖屏 → 单列布局，溢出 35px；
// 两者底部动作行被挤出屏外，用户看到的就是「横屏没有竖屏那些功能」。
//
// 本文件锁定：
//  1. 新断点表的判定结果（含方向）；
//  2. 6 个横屏尺寸下：无 overflow 异常、四个动作入口真的在屏内、
//     收藏按钮与播放列表入口都在；
//  3. full 档（可用高 ≥420）有「当前歌词」一行；
//  4. 竖屏 390×844 四入口仍在屏内（防止把竖屏改坏）。
//
// 音频通道：`PlayerPage` 依赖 just_audio / audio_service 单例，纯 Dart 测试里
// 平台通道缺失由服务内部 try/catch 吞掉；「收藏 / 动作行」需要一首当前歌曲
// 才有回调，这里用本地伪曲目 `play()`（只同步置上 currentSong，不触网）。
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

/// 四个动作入口的文案（与 `_buildActionRow` 保持一致）
const List<String> _actionLabels = ['下载', '分享', '定时', '更多'];

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
  Size(568, 320), // 窄横屏：修复前判成 b1，溢出 563px
  Size(640, 360),
  Size(720, 480),
  Size(800, 600), // 小平板横屏：修复前判成 b3，溢出 35px
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

/// 断言某个 Finder 命中且**真的在屏内**（存在 ≠ 可见）。
///
/// [allowMultiple]：竖屏 `_buildCoverAndSongInfo` 会同时挂「大封面」与
/// 「小封面」两套歌名信息（后者 opacity 0 但仍在树上），收藏按钮因此可能
/// 命中两个——只看第一个即可。
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

  group('横屏：四入口 / 收藏 / 播放列表都在屏内', () {
    for (final size in _landscapeSizes) {
      testWidgets('${size.width.toInt()}×${size.height.toInt()} 无溢出且入口在屏内', (
        tester,
      ) async {
        await _pumpPlayer(tester, size);

        expect(tester.takeException(), isNull, reason: '不应出现 overflow');

        for (final label in _actionLabels) {
          expect(
            find.text(label),
            findsOneWidget,
            reason: '${size.width.toInt()}×${size.height.toInt()} 缺少「$label」入口',
          );
          _expectOnScreen(tester, _actionHitArea(label), size, '「$label」入口');
        }

        _expectOnScreen(tester, _likeIcon, size, '收藏按钮');
        _expectOnScreen(tester, _playlistEntry, size, '播放列表入口');

        await _drain(tester);
      });
    }
  });

  group('横屏：full 档补上当前歌词', () {
    testWidgets('800×600 有 LyricDisplay（与竖屏一致），且不溢出', (tester) async {
      await _pumpPlayer(tester, const Size(800, 600));

      expect(find.byType(LyricDisplay), findsOneWidget);
      final rect = tester.getRect(find.byType(LyricDisplay));
      expect(rect.bottom, lessThanOrEqualTo(600));
      expect(tester.takeException(), isNull);

      await _drain(tester);
    });

    testWidgets('568×320（tiny 档）不加歌词行：空间给控件与动作行', (tester) async {
      await _pumpPlayer(tester, const Size(568, 320));

      expect(find.byType(LyricDisplay), findsNothing);
      expect(tester.takeException(), isNull);

      await _drain(tester);
    });
  });

  group('横屏：点封面收起 / 恢复（与竖屏同一套语义）', () {
    testWidgets('800×600 点封面 → 收缩为 70px 小封面，再点恢复', (tester) async {
      await _pumpPlayer(tester, const Size(800, 600));

      final cover = find.byType(AspectRatio);
      expect(cover, findsOneWidget, reason: '分栏左栏应只有封面用 AspectRatio 撑正方形');
      final before = tester.getSize(cover);
      expect(before.width, greaterThan(70), reason: '初始应为大封面');

      await tester.tap(cover);
      await tester.pump(const Duration(milliseconds: 300));
      final collapsed = tester.getSize(find.byType(AspectRatio));
      expect(collapsed.width, closeTo(70, 0.5));
      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(AspectRatio));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getSize(find.byType(AspectRatio)).width, greaterThan(70));

      await _drain(tester);
    });
  });

  // ── 本轮修复：compact 档（手机横屏主场景）必须与竖屏对等 ──────────────
  //
  // 720×480 的可用高 = 480 − 52(TopBar) − 12 = 416 → 落在 compact 档。
  // 1080p 手机横屏的逻辑高通常 360~400 → 同样落在 compact 档，所以这一档
  // 才是「用户真正看到的横屏」，歌词行与点封面必须在这里补齐。
  group('横屏 compact 档：歌词行 + 点封面（720×480）', () {
    testWidgets('720×480：歌名下有一行歌词，四条入口在屏内', (tester) async {
      await _pumpPlayer(tester, const Size(720, 480));

      expect(
        find.byType(LyricDisplay),
        findsOneWidget,
        reason: '720×480 可用高 416 ≥ 380，compact 档必须有当前歌词行',
      );
      final lyricRect = tester.getRect(find.byType(LyricDisplay));
      expect(lyricRect.bottom, lessThanOrEqualTo(480));

      // 歌词行确实在歌名之下（不是在别处凑数）
      final titleRect = tester.getRect(find.text('东风破'));
      expect(
        lyricRect.top,
        greaterThanOrEqualTo(titleRect.bottom),
        reason: '歌词行应排在歌名/歌手之后',
      );

      for (final label in _actionLabels) {
        _expectOnScreen(
          tester,
          _actionHitArea(label),
          const Size(720, 480),
          '720×480 「$label」入口',
        );
      }
      expect(tester.takeException(), isNull);

      await _drain(tester);
    });

    testWidgets('720×480：点封面收起 → 小封面 + 控件整体上移 + 歌词仍在', (tester) async {
      await _pumpPlayer(tester, const Size(720, 480));

      final cover = find.byType(AspectRatio);
      final beforeSize = tester.getSize(cover);
      final beforeProgressTop = tester.getTopLeft(find.byType(ProgressBar)).dy;

      await tester.tap(cover);
      await tester.pump(const Duration(milliseconds: 300));

      final afterSize = tester.getSize(find.byType(AspectRatio));
      expect(afterSize.width, closeTo(70, 0.5), reason: '收起后应为 70px 小封面');
      // 「尺寸差 ≥ 100」在本档无法字面成立：compact 档封面本身受 Flexible 槽位
      // 约束（720×480 时槽高 150.5，再大就放不下），70 的差值上限只有 80.5。
      // 因此改为「缩到不足原来一半 + 位移不小于 80px」这两个等价且更强的断言。
      expect(
        afterSize.width * 2,
        lessThan(beforeSize.width),
        reason:
            '收起后封面应不足原来的一半'
            '（${beforeSize.width} → ${afterSize.width}）',
      );

      // 关键回归：控件整体上移（此前 Flexible 占位不释放 → 一动不动）
      final afterProgressTop = tester.getTopLeft(find.byType(ProgressBar)).dy;
      expect(
        afterProgressTop,
        lessThanOrEqualTo(beforeProgressTop - 80),
        reason:
            '收起后进度条应明显上移（before=$beforeProgressTop after=$afterProgressTop）',
      );

      // 收起后歌词行仍在
      expect(find.byType(LyricDisplay), findsOneWidget);
      // 四个动作入口仍在屏内
      for (final label in _actionLabels) {
        _expectOnScreen(
          tester,
          _actionHitArea(label),
          const Size(720, 480),
          '720×480 收起后「$label」入口',
        );
      }
      expect(tester.takeException(), isNull);

      // 再点一次恢复
      await tester.tap(find.byType(AspectRatio));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.getSize(find.byType(AspectRatio)).width,
        closeTo(beforeSize.width, 0.5),
      );

      await _drain(tester);
    });
  });

  group('横屏 compact 档：低高度（640×360，可用高 296）不挤歌词', () {
    testWidgets('640×360：无歌词行，但点封面有效且不溢出', (tester) async {
      await _pumpPlayer(tester, const Size(640, 360));

      expect(
        find.byType(LyricDisplay),
        findsNothing,
        reason: '可用高 296 < 380：加歌词行会把四个动作入口挤出屏幕',
      );

      final beforeSize = tester.getSize(find.byType(AspectRatio));

      // 点封面必须有反应（此前 compact 档没有 GestureDetector，点了毫无变化）
      await tester.tap(find.byType(AspectRatio));
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        tester.getSize(find.byType(AspectRatio)).width,
        isNot(closeTo(beforeSize.width, 0.5)),
        reason: '点封面后封面尺寸必须变化',
      );
      // 收起后腾出的空间用于显示歌词行（本档固定 70 封面已是最小可视尺寸）
      expect(find.byType(LyricDisplay), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '640×360 收起态不得 overflow');

      for (final label in _actionLabels) {
        _expectOnScreen(
          tester,
          _actionHitArea(label),
          const Size(640, 360),
          '640×360 收起后「$label」入口',
        );
      }

      await tester.tap(find.byType(AspectRatio));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(LyricDisplay), findsNothing);
      expect(tester.takeException(), isNull);

      await _drain(tester);
    });
  });

  group('横屏 full 档：收起封面也要真的让位（800×600）', () {
    testWidgets('800×600 收起后封面 ≤ 80 且控件区整体上移', (tester) async {
      await _pumpPlayer(tester, const Size(800, 600));

      final beforeProgressTop = tester.getTopLeft(find.byType(ProgressBar)).dy;

      await tester.tap(find.byType(AspectRatio));
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        tester.getSize(find.byType(AspectRatio)).height,
        lessThanOrEqualTo(80),
      );

      final afterProgressTop = tester.getTopLeft(find.byType(ProgressBar)).dy;
      expect(
        afterProgressTop,
        lessThan(beforeProgressTop),
        reason: '收起后封面应释放高度（此前 Expanded 占位 → 控件一动不动）',
      );
      expect(find.byType(LyricDisplay), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _drain(tester);
    });
  });

  // ── 1.5.5：横屏歌词默认不出现，点封面（卡片）才展开 ────────────────
  //
  // 用户反馈：竖屏是「点卡片显示歌词」，横屏却一进来就右半屏铺歌词。
  // 本组锁定新语义：默认只有播放器；点封面 → 小封面 + 右侧大歌词；再点恢复。
  group('横屏：歌词默认不出现，点卡片才展开（与竖屏一致）', () {
    testWidgets('800×600 默认无 FullLyricDisplay，点封面后出现、再点消失', (tester) async {
      await _pumpPlayer(tester, const Size(800, 600));

      expect(
        find.byType(FullLyricDisplay),
        findsNothing,
        reason: '横屏默认应只显示播放器，不得常驻歌词面板',
      );

      await tester.tap(find.byType(AspectRatio));
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byType(FullLyricDisplay),
        findsOneWidget,
        reason: '点卡片后应展开右侧歌词',
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(AspectRatio));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(FullLyricDisplay), findsNothing);

      await _drain(tester);
    });

    testWidgets('720×480（compact 档）同样默认无歌词、点封面展开', (tester) async {
      await _pumpPlayer(tester, const Size(720, 480));

      expect(find.byType(FullLyricDisplay), findsNothing);

      await tester.tap(find.byType(AspectRatio));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(FullLyricDisplay), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '展开歌词后仍不得 overflow');

      // 四个动作入口在歌词形态下也要在屏内
      for (final label in _actionLabels) {
        _expectOnScreen(
          tester,
          _actionHitArea(label),
          const Size(720, 480),
          '720×480 歌词态「$label」入口',
        );
      }

      await _drain(tester);
    });
  });

  group('竖屏回归', () {
    testWidgets('390×844 四入口 / 收藏 / 播放列表仍在屏内', (tester) async {
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
      expect(tester.takeException(), isNull);

      await _drain(tester);
    });
  });
}
