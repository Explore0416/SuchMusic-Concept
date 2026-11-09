// 1.4.0 收尾批次：我的 / 设置 / 歌单三页的视觉与文案收敛。
//
// 覆盖用户三条评审意见：
//  - 意见 3（颜色与图标）：身份卡与喜欢卡不再铺大面积彩色，辅助文字只用墨阶，
//    图标统一 *_rounded，强调色只剩 brand（选中 / 主操作）与 rose（红心）；
//  - 意见 5（文案瘦身）：列表项 = 图标 + 主文字，设置页抽样项不再有 subtitle；
//  - 意见 2 收尾：我的页身份卡下方有双音源登录态行，未登录点音源胶囊只提示不切换。
//
// 另外锁定两个定案修正：HotRankRow 分隔线缩进 76。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/screens/library_page.dart';
import 'package:such_music/screens/profile_page.dart';
import 'package:such_music/screens/settings_page.dart';
import 'package:such_music/services/app_init.dart';
import 'package:such_music/services/sources/source_manager.dart';
import 'package:such_music/services/user_library_service.dart';
import 'package:such_music/theme/app_theme.dart';
import 'package:such_music/widgets/app_ui.dart';
import 'package:such_music/widgets/design_dialog.dart';
import 'package:such_music/widgets/home_sections.dart';
import 'package:such_music/widgets/source_switcher.dart';

/// 固定屏幕尺寸（逻辑像素），避免受默认 800×600 影响
void _useSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(backgroundColor: AppColors.canvas, body: child),
);

/// 读取某个 key 上的 [BoxDecoration]。
///
/// key 落在 Container 自身（卡片）时直接读；落在包装组件上（如圆点）时
/// 向下找最近的一个带 [BoxDecoration] 的 Container。
BoxDecoration _decorationOf(WidgetTester tester, Key key) {
  final target = find.byKey(key);
  final self = tester.widget(target);
  if (self is Container && self.decoration is BoxDecoration) {
    return self.decoration! as BoxDecoration;
  }
  final containers = find.descendant(
    of: target,
    matching: find.byType(Container),
  );
  for (final element in containers.evaluate()) {
    final widget = element.widget as Container;
    if (widget.decoration is BoxDecoration) {
      return widget.decoration! as BoxDecoration;
    }
  }
  fail('$key 下没有找到带 BoxDecoration 的 Container');
}

/// 读取某个 key 落在 [Container] 上的纯色（圆点 / 卡片底色）
Color? _colorOf(WidgetTester tester, Key key) =>
    _decorationOf(tester, key).color;

/// 造 [n] 首假歌（排行行只关心文字与序号，不需要真实封面）
List<SongModel> _songs(int n) => List<SongModel>.generate(
  n,
  (i) => SongModel(
    id: 'song-$i',
    name: '歌曲${i + 1}',
    artist: '歌手${i + 1}',
    album: '专辑',
    source: SongSource.netease,
  ),
);

Widget _stubCover(double side) =>
    Container(width: side, height: side, color: AppColors.surfaceMuted);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    DesignToast.debugReset();
    markInitialized();
  });

  tearDown(() async {
    // 音源是全局单例：用例结束后复位，避免互相影响
    await SourceManager().switchTo(SongSource.netease);
  });

  // ── 意见 3：我的页身份卡 ────────────────────────────────
  group('我的页身份卡', () {
    testWidgets('不再使用渐变：纯白面 + 0.7 发丝线', (tester) async {
      _useSize(tester, const Size(430, 932));
      await tester.pumpWidget(_host(const ProfilePage()));
      await tester.pump();
      await tester.pump();

      final decoration = _decorationOf(tester, profileIdentityCardKey);
      expect(decoration.gradient, isNull, reason: '冷蓝渐变属于大面积彩色，必须去掉');
      expect(decoration.color, AppColors.surface, reason: '底色回到卡面白');
      final border = decoration.border;
      expect(border, isA<Border>());
      expect((border! as Border).top.color, AppColors.hairline);
      expect((border as Border).top.width, 0.7);

      expect(tester.takeException(), isNull);
    });

    testWidgets('身份卡下的辅助说明与「图标 + 主文字 + 说明」三件套已删除', (tester) async {
      _useSize(tester, const Size(430, 932));
      await tester.pumpWidget(_host(const ProfilePage()));
      await tester.pump();
      await tester.pump();

      // 副标题 / 说明行
      expect(find.text('登录后同步歌单与每日推荐'), findsNothing);
      expect(find.text('音效、下载、关于与更新'), findsNothing);
      expect(find.textContaining('已连接'), findsNothing);
      // 「登录后可以」三行只剩标题
      expect(find.text('云端歌单'), findsOneWidget);
      expect(find.text('这里会列出你在网易云、酷狗收藏的歌单'), findsNothing);
      expect(find.text('按你实际听的口味每天换一批，不用再猜'), findsNothing);
      expect(find.text('网易云与酷狗分别登录，缺歌时自动换源'), findsNothing);
      // 禁用中点
      expect(find.textContaining('·'), findsNothing);

      expect(tester.takeException(), isNull);
    });
  });

  // ── 意见 2 收尾：双音源登录态 ───────────────────────────
  group('我的页双音源登录态', () {
    testWidgets('身份卡下方有两个「圆点 + 名称」，未登录时圆点置灰、文字三级灰', (tester) async {
      _useSize(tester, const Size(430, 932));
      await tester.pumpWidget(_host(const ProfilePage()));
      await tester.pump();
      await tester.pump();

      expect(find.byType(SourceStatusRow), findsOneWidget);
      expect(find.byKey(sourceStatusRowKey), findsOneWidget);
      expect(find.text('网易云'), findsOneWidget);
      expect(find.text('酷狗'), findsOneWidget);

      // 测试环境没有凭证：两个圆点都是 inkDisabled，文字是 inkTertiary
      final dots = tester.widgetList<SourceStatusDot>(
        find.byType(SourceStatusDot),
      );
      expect(dots.length, 2);
      expect(dots.every((d) => d.loggedIn == false), isTrue);
      expect(
        _colorOf(tester, sourceStatusRowNeteaseDotKey),
        AppColors.inkDisabled,
      );
      expect(
        _colorOf(tester, sourceStatusRowKugouDotKey),
        AppColors.inkDisabled,
      );

      final label = tester.widget<Text>(find.text('网易云'));
      expect(label.style?.color, AppColors.inkTertiary);
      expect(label.style?.fontSize, 12);

      // 登录后用品牌蓝点亮：「已登录 brand」由 SourceStatusDot 语义保证
      await tester.pumpWidget(
        _host(
          const Row(
            children: [
              SourceStatusDot(key: Key('dot-logged'), loggedIn: true),
              SourceStatusDot(key: Key('dot-anon'), loggedIn: false),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(_colorOf(tester, const Key('dot-logged')), AppColors.brand);
      expect(_colorOf(tester, const Key('dot-anon')), AppColors.inkDisabled);

      expect(tester.takeException(), isNull);
    });
  });

  // ── 意见 5：设置页文案瘦身 ──────────────────────────────
  group('设置页文案瘦身', () {
    testWidgets('抽样 5 个关键项都只剩「图标 + 主文字」，没有 subtitle', (tester) async {
      // 一屏放得下，所有分组项都会被 build，抽样才有意义
      _useSize(tester, const Size(430, 1400));
      await tester.pumpWidget(_host(const SettingsPage()));
      await tester.pumpAndSettle();

      const sampled = <String>[
        '与其他应用同时播放',
        '当前音源',
        '酷狗账号',
        '音效',
        '手环',
        '配置备份',
        '关于 SuchMusic 概念版',
      ];
      for (final title in sampled) {
        final finder = find.widgetWithText(AppListTile, title);
        expect(finder, findsOneWidget, reason: '设置页应有「$title」这一行');
        final tile = tester.widget<AppListTile>(finder);
        expect(tile.subtitle, isNull, reason: '「$title」的辅助说明应删除');
      }

      // 整页没有任何一行带 subtitle
      final all = tester.widgetList<AppListTile>(find.byType(AppListTile));
      expect(all, isNotEmpty);
      expect(
        all.every((t) => t.subtitle == null),
        isTrue,
        reason: '设置页列表项一律「图标 + 主文字」',
      );

      // 被删掉的说明文案确实不在了
      expect(find.text('音乐可和视频、游戏的声音共存'), findsNothing);
      expect(find.text('搜索与播放都走这个源'), findsNothing);
      expect(find.text('均衡器预设：流行 / 人声 / 重低音 / 环绕'), findsNothing);

      // 分组标题保留（它是必要的层级，不删）
      for (final group in ['播放', '音源', '数据', '关于']) {
        expect(find.text(group), findsOneWidget);
      }

      expect(tester.takeException(), isNull);
    });

    testWidgets('删掉说明后一屏能看到全部分组项（11 项，无需滚动）', (tester) async {
      _useSize(tester, const Size(430, 932));
      await tester.pumpWidget(_host(const SettingsPage()));
      await tester.pumpAndSettle();

      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;

      // 「完整可见」的分组项：底边落在视口内
      var visible = 0;
      for (final element in find.byType(AppListTile).evaluate()) {
        final box = element.renderObject! as RenderBox;
        final top = box.localToGlobal(Offset.zero).dy;
        if (top + box.size.height <= position.viewportDimension) visible++;
      }

      expect(
        find.byType(AppListTile).evaluate().length,
        11,
        reason: '播放 2 + 音源 5 + 数据 3 + 关于 1',
      );
      expect(visible, 11, reason: '文案瘦身后一屏放得下全部分组项（旧布局只放得下 9 项）');
      expect(position.maxScrollExtent, lessThan(24), reason: '至多滚一丁点');

      expect(tester.takeException(), isNull);
    });
  });

  // ── 意见 3：歌单页喜欢卡 ────────────────────────────────
  group('歌单页喜欢卡', () {
    testWidgets('底色回到白面 + 发丝线，彩色只留在红心图标上', (tester) async {
      _useSize(tester, const Size(430, 932));
      await UserLibraryService.instance.init();
      await tester.pumpWidget(_host(const LibraryPage()));
      await tester.pumpAndSettle();

      final decoration = _decorationOf(tester, libraryLikedCardKey);
      expect(decoration.gradient, isNull);
      expect(decoration.color, AppColors.surface);
      expect((decoration.border! as Border).top.color, AppColors.hairline);

      // 红心仍是唯一彩色
      final heart = tester.widget<Icon>(find.byIcon(Icons.favorite_rounded));
      expect(heart.color, AppColors.rose);

      expect(tester.takeException(), isNull);
    });
  });

  // ── 定案修正：未登录点音源胶囊只引导，不切换 ─────────────
  group('音源胶囊登录门禁', () {
    testWidgets('未登录点击酷狗只出提示，音源不变', (tester) async {
      _useSize(tester, const Size(430, 932));
      await tester.pumpWidget(_host(const SourceSwitcher()));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(sourceSwitcherKugouPillKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(SourceManager().currentSource, SongSource.netease);
      expect(find.text('请先在「我的」页登录酷狗账号'), findsOneWidget);
      expect(_colorOf(tester, sourceSwitcherNeteasePillKey), AppColors.ink);

      // 收回 Toast 的 2 秒定时器
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
    });
  });

  // ── 定案修正：排行行分隔线缩进 76 ───────────────────────
  group('热歌推荐分隔线', () {
    testWidgets('左缩进 76 = 序号 28 + 间距 8 + 封面 40', (tester) async {
      _useSize(tester, const Size(390, 844));

      expect(HotRankRow.dividerIndent, 76);

      await tester.pumpWidget(
        _host(
          HotRankList(
            songs: _songs(3),
            coverOf: (song, side) => _stubCover(side),
            onSongTap: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final hairlines = tester.widgetList<AppHairline>(
        find.descendant(
          of: find.byType(HotRankList),
          matching: find.byType(AppHairline),
        ),
      );
      expect(hairlines, isNotEmpty);
      expect(hairlines.every((h) => h.indent == 76), isTrue);

      expect(tester.takeException(), isNull);
    });
  });

  // ── 意见 3：彩色出现点收敛（源码级回归闸） ───────────────
  group('彩色与图标收敛', () {
    /// 本批次负责的页面：只允许 brand / rose 两种彩色令牌
    const pages = <String>[
      'lib/screens/profile_page.dart',
      'lib/screens/settings_page.dart',
      'lib/screens/library_page.dart',
      'lib/screens/user_playlist_detail_page.dart',
      'lib/screens/kugou_playlist_page.dart',
      'lib/widgets/source_switcher.dart',
    ];

    test('页面里不出现 success / warning / danger 与具名彩色', () {
      const banned = <String>[
        'AppColors.success',
        'AppColors.successSoft',
        'AppColors.warning',
        'AppColors.warningSoft',
        'AppColors.danger',
        'AppColors.dangerSoft',
        'Colors.blue',
        'Colors.red',
        'Colors.green',
        'Colors.orange',
        'Colors.purple',
        'Colors.pink',
        'Colors.amber',
        'Color(0x',
      ];
      for (final path in pages) {
        final source = File(path).readAsStringSync();
        for (final token in banned) {
          expect(
            source.contains(token),
            isFalse,
            reason: '$path 不应再出现 $token（彩色只允许 brand / rose）',
          );
        }
      }
    });

    test('图标统一 *_rounded，且不再出现中点', () {
      for (final path in pages) {
        final source = File(path).readAsStringSync();
        expect(
          source.contains('_outlined'),
          isFalse,
          reason: '$path 的图标应统一成 *_rounded',
        );
        expect(source.contains('·'), isFalse, reason: '$path 不应出现中点');
      }
    });
  });
}
