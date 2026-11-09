// 1.4.0 首页重构（意见 6 / 4.1 / 2 / 5）的验收测试。
//
// 覆盖：
//  - 首页常驻搜索框：高 44、有占位文案、可点进搜索页，且 header 的放大镜已删除
//    （搜索入口只留一个）；
//  - 三个区块使用三种不同的 item 组件（横卡 / 网格 / 排行行），形状（宽高、数量）
//    各不相同，热歌区序号 01–05、分割线左缩进 68；
//  - SourceSwitcher：默认选中网易云、点击切到酷狗并走 SourceManager 真接口、
//    登录态圆点颜色（已登录 brand / 未登录 inkDisabled）；
//  - 三个区块骨架屏形状不同（横卡骨架 / 网格骨架 / 列表骨架）；
//  - 区块间距统一 36，区块标题下的说明文案已删除。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netease_music_api/netease_music_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/screens/home_page.dart';
import 'package:such_music/screens/search_page.dart';
import 'package:such_music/services/sources/source_manager.dart';
import 'package:such_music/theme/app_theme.dart';
import 'package:such_music/widgets/app_ui.dart';
import 'package:such_music/widgets/design_dialog.dart';
import 'package:such_music/widgets/home_sections.dart';
import 'package:such_music/widgets/source_switcher.dart';

/// 测试用路径提供者：把网易云 SDK 的 cookie / 数据目录指到临时目录，
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

/// 造 [n] 首假歌，用于验证各区块的展示条数与排版
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

/// 封面替身：不触网，只占位（区块组件本身不负责取图）
Widget _stubCover(double side) =>
    Container(width: side, height: side, color: AppColors.surfaceMuted);

/// 排空首页 initState 发起的后台网络请求（dio 的零延时 / 超时定时器），
/// 否则用例结束时会报「A Timer is still pending」。
Future<void> _drainBackgroundRequests(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

/// 读取某个 key 下（含自身）第一个带 [BoxDecoration] 的 Container 底色。
///
/// 胶囊的 key 直接落在 Container 上，登录态圆点的 key 落在包装组件上，
/// 两种都要能读，所以向下遍历一层而不是强转类型。
Color? _bgColorOf(WidgetTester tester, Key key) {
  BoxDecoration? found;
  void visit(Element element) {
    if (found != null) return;
    final widget = element.widget;
    if (widget is Container && widget.decoration is BoxDecoration) {
      found = widget.decoration! as BoxDecoration;
      return;
    }
    element.visitChildren(visit);
  }

  visit(tester.element(find.byKey(key).first));
  return found?.color;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // 首页的「猜你想听」会调网易云 SDK 取新歌；SDK 的登录态控制器在构造时会
    // fire-and-forget 地写 cookie 文件，未设 pathProvider 会抛 LateError（未捕获）。
    final dir = await Directory.systemTemp.createTemp('suchmusic_home_test');
    await NeteaseMusicApi.init(provider: _TempPathProvider(dir.path));
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    DesignToast.debugReset();
  });

  tearDown(() async {
    // 音源是全局单例：用例结束后复位，避免互相影响
    await SourceManager().switchTo(SongSource.netease);
  });

  // ── 意见 4.1：常驻搜索框 ────────────────────────────────
  group('首页常驻搜索框', () {
    testWidgets('搜索框在页面顶部、高 44、有占位文案，点击进入搜索页', (tester) async {
      _useSize(tester, const Size(390, 844));
      await tester.pumpWidget(_host(const HomePage()));
      await tester.pump();

      expect(find.byType(HomeSearchEntry), findsOneWidget);
      expect(find.text('搜索歌曲、歌手、歌单'), findsOneWidget);
      expect(
        tester.getSize(find.byType(HomeSearchEntry)).height,
        44,
        reason: '搜索框高度必须为 44',
      );

      // 搜索入口只留一个：header 右上角的放大镜按钮已删除（仅剩搜索框内的图标）
      expect(find.byIcon(Icons.search_rounded), findsOneWidget);

      await tester.tap(find.byType(HomeSearchEntry));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(SearchPage), findsOneWidget, reason: '整框可点即进搜索页');
      expect(tester.takeException(), isNull);
      await _drainBackgroundRequests(tester);
    });
  });

  // ── 意见 6：三区块形状差异 ──────────────────────────────
  group('三个区块使用三种不同的 item 组件', () {
    testWidgets('横卡 / 网格 / 排行行的组件类型与形状互不相同', (tester) async {
      _useSize(tester, const Size(390, 844));
      final songs = _songs(8);

      await tester.pumpWidget(
        _host(
          SingleChildScrollView(
            child: Column(
              children: [
                PickRail(
                  songs: songs,
                  coverOf: (song, side) => _stubCover(side),
                  onSongTap: (_) {},
                ),
                DailyGrid(
                  songs: songs,
                  coverOf: (song, side) => _stubCover(side),
                  onSongTap: (_) {},
                ),
                HotRankList(
                  songs: songs,
                  coverOf: (song, side) => _stubCover(side),
                  onSongTap: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 三种组件类型同时存在，且互不相同
      expect(find.byType(PickRailCard), findsNWidgets(8));
      expect(find.byType(DailyGridCard), findsNWidgets(6), reason: '只展示前 6 首');
      expect(find.byType(HotRankRow), findsNWidgets(5), reason: '只展示前 5 首');

      // 形状差异：横卡 148 宽 / 网格两列 / 排行行 56 高
      expect(tester.getSize(find.byType(PickRailCard).first).width, 148);
      expect(
        tester.getSize(find.byType(DailyGridCard).first).width,
        closeTo((390 - AppSpace.page * 2 - 12) / 2, 0.5),
      );
      expect(tester.getSize(find.byType(HotRankRow).first).height, 56.7,
          reason: '行高 56 + 行间 0.7 发丝线');

      // 排行区：序号 01–05
      for (final seq in ['01', '02', '03', '04', '05']) {
        expect(find.text(seq), findsOneWidget, reason: '排行序号应有 $seq');
      }
      expect(find.text('06'), findsNothing, reason: '排行只展示前 5 首');

      // 行间发丝线左缩进 76 = 序号 28 + 间距 8 + 封面 40（与封面右缘对齐）
      expect(HotRankRow.dividerIndent, 76);
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

    testWidgets('点击各区块条目都会回调对应歌曲', (tester) async {
      _useSize(tester, const Size(390, 844));
      final songs = _songs(3);
      final tapped = <String>[];

      await tester.pumpWidget(
        _host(
          SingleChildScrollView(
            child: Column(
              children: [
                PickRail(
                  songs: songs,
                  coverOf: (song, side) => _stubCover(side),
                  onSongTap: (song) => tapped.add('pick:${song.id}'),
                ),
                DailyGrid(
                  songs: songs,
                  coverOf: (song, side) => _stubCover(side),
                  onSongTap: (song) => tapped.add('daily:${song.id}'),
                ),
                HotRankList(
                  songs: songs,
                  coverOf: (song, side) => _stubCover(side),
                  onSongTap: (song) => tapped.add('hot:${song.id}'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PickRailCard).first);
      await tester.tap(find.byType(DailyGridCard).first);
      await tester.tap(find.byType(HotRankRow).first);
      await tester.pump();

      expect(tapped, ['pick:song-0', 'daily:song-0', 'hot:song-0']);
      expect(tester.takeException(), isNull);
    });
  });

  // ── 骨架屏：三种形状 ────────────────────────────────────
  group('三个区块的骨架屏各按自身形状渲染', () {
    testWidgets('横向卡骨架 / 网格骨架 / 列表骨架的数量与类型不同', (tester) async {
      _useSize(tester, const Size(390, 844));

      await tester.pumpWidget(
        _host(
          SingleChildScrollView(
            child: Column(
              children: [
                const PickRailSkeleton(),
                DailyGrid(
                  songs: const <SongModel>[],
                  coverOf: (song, side) => _stubCover(side),
                  onSongTap: (_) {},
                  loading: true,
                ),
                HotRankList(
                  songs: const <SongModel>[],
                  coverOf: (song, side) => _stubCover(side),
                  onSongTap: (_) {},
                  loading: true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 横卡骨架：3 张大封面块（148）
      expect(find.byType(PickRailSkeleton), findsOneWidget);
      expect(find.byType(DailyGridSkeletonCard), findsNWidgets(6));
      expect(find.byType(HotRankSkeletonRow), findsNWidgets(5));

      final railSkeleton = tester.getSize(
        find
            .descendant(
              of: find.byType(PickRailSkeleton),
              matching: find.byType(AppSkeleton),
            )
            .first,
      );
      expect(railSkeleton.width, PickRailCard.side);

      expect(tester.takeException(), isNull);
    });
  });

  // ── 意见 2：双音源切换器 ────────────────────────────────
  group('SourceSwitcher', () {
    testWidgets('默认选中网易云；未登录点酷狗只提示去登录，不切换', (tester) async {
      await tester.pumpWidget(_host(const SourceSwitcher()));
      await tester.pump();
      await tester.pump();

      expect(
        _bgColorOf(tester, sourceSwitcherNeteasePillKey),
        AppColors.ink,
        reason: '选中态：墨色实心',
      );
      expect(
        _bgColorOf(tester, sourceSwitcherKugouPillKey),
        AppColors.surfaceMuted,
        reason: '未选中：浅灰底',
      );

      await tester.tap(find.byKey(sourceSwitcherKugouPillKey));
      await tester.pump();
      await tester.pump();

      // 未登录时胶囊只做引导，不切源：硬切过去会拿到一片空白
      expect(
        SourceManager().currentSource,
        SongSource.netease,
        reason: '未登录不得切换音源',
      );
      expect(
        find.text(sourceLoginHintFor(SongSource.kugou)),
        findsOneWidget,
        reason: '应提示先去「我的」页登录',
      );
      expect(
        _bgColorOf(tester, sourceSwitcherNeteasePillKey),
        AppColors.ink,
        reason: '选中态不变',
      );
      expect(
        _bgColorOf(tester, sourceSwitcherKugouPillKey),
        AppColors.surfaceMuted,
      );

      // 收回 Toast 的 2 秒定时器
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
    });

    testWidgets('已选中项再点不重复切换（幂等）', (tester) async {
      await SourceManager().switchTo(SongSource.kugou);
      await tester.pumpWidget(_host(const SourceSwitcher()));
      await tester.pump();

      await tester.tap(find.byKey(sourceSwitcherKugouPillKey));
      await tester.pump();
      await tester.pump();

      expect(SourceManager().currentSource, SongSource.kugou);
      expect(find.textContaining('已切换音源'), findsNothing, reason: '同音源不提示');
      expect(tester.takeException(), isNull);
    });

    testWidgets('登录态圆点：已登录 brand，未登录 inkDisabled', (tester) async {
      await tester.pumpWidget(
        _host(
          const Row(
            children: [
              SourceStatusDot(key: Key('dot-on'), loggedIn: true),
              SourceStatusDot(key: Key('dot-off'), loggedIn: false),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(_bgColorOf(tester, const Key('dot-on')), AppColors.brand);
      expect(
        _bgColorOf(tester, const Key('dot-off')),
        AppColors.inkDisabled,
      );

      // 切换器里两个音源各带一个圆点；测试环境没有凭证 → 都是置灰
      await tester.pumpWidget(_host(const SourceSwitcher()));
      await tester.pump();
      expect(find.byType(SourceStatusDot), findsNWidgets(2));

      expect(tester.takeException(), isNull);
    });
  });

  // ── 间距与文案：需求 6.4 + 意见 5 首页部分 ───────────────
  group('首页间距与文案', () {
    testWidgets('区块间距统一 36，区块标题下不再挂说明文案', (tester) async {
      _useSize(tester, const Size(390, 844));
      await tester.pumpWidget(_host(const HomePage()));
      await tester.pump();

      expect(HomeSectionSpacer.height, 36);

      final spacers = find.byType(HomeSectionSpacer);
      expect(spacers.evaluate().length, greaterThanOrEqualTo(2));
      for (var i = 0; i < spacers.evaluate().length; i++) {
        expect(tester.getSize(spacers.at(i)).height, 36);
      }

      // 三个区块的标题都在（猜你想听无本机播放记录时整块隐藏，故不强制）
      expect(find.text('每日推荐'), findsOneWidget);
      expect(find.text('热歌推荐'), findsOneWidget);

      // 意见 5：subtitle 已删除
      expect(find.text('每天更新，为你挑 12 首'), findsNothing);
      expect(find.text('根据本机播放记录挑选'), findsNothing);

      expect(tester.takeException(), isNull);
      await _drainBackgroundRequests(tester);
    });
  });
}
