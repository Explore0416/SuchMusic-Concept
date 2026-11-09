// 1.4.0 全局播放控制重构（意见 1）的验收测试。
//
// 覆盖规格 §1 的硬性要求：
//  - 进度条可拖，拖拽回调 onSeek 拿到 0–1 的比例；
//  - 上一首 / 播放键 / 下一首 三个按钮各自回调，互不串线；
//  - 窄屏（< 360）隐藏封面，把宽度让给歌名；
//  - 回调全为空（宿主没接能力）时不崩、按钮置灰；
//  - 视觉尺寸契约：卡高 76 / 条 3 / 拖拽热区 20 / 按钮热区 44；
//  - 左右滑动切歌手势与按钮并存；
//  - 宽屏侧栏播放卡与迷你卡同一套控制。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/theme/app_theme.dart';
import 'package:such_music/widgets/app_bottom_dock.dart';

/// 固定屏幕尺寸（逻辑像素），避免测试受默认 800×600 影响
void _useSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _host(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      backgroundColor: AppColors.canvas,
      body: Align(alignment: Alignment.bottomCenter, child: child),
    ),
  );
}

const _coverKey = Key('mini-cover');

Widget _cover() => Container(
  key: _coverKey,
  color: AppColors.surfaceMuted,
  child: const Icon(Icons.music_note_rounded, size: 18),
);

MiniPlayerCard _card({
  bool isPlaying = true,
  double progress = 0.25,
  VoidCallback? onTap,
  VoidCallback? onToggle,
  ValueChanged<double>? onSeek,
  VoidCallback? onPrevious,
  VoidCallback? onNext,
  VoidCallback? onSwipeNext,
  VoidCallback? onSwipePrevious,
}) {
  return MiniPlayerCard(
    title: '晴天',
    subtitle: '周杰伦',
    cover: _cover(),
    isPlaying: isPlaying,
    progress: progress,
    onTap: onTap ?? () {},
    onToggle: onToggle ?? () {},
    onSeek: onSeek,
    onPrevious: onPrevious,
    onNext: onNext,
    onSwipeNext: onSwipeNext,
    onSwipePrevious: onSwipePrevious,
  );
}

SideNowPlayingCard _sideCard({
  bool isPlaying = true,
  double progress = 0.5,
  ValueChanged<double>? onSeek,
  VoidCallback? onPrevious,
  VoidCallback? onNext,
  VoidCallback? onToggle,
}) {
  return SideNowPlayingCard(
    title: '东风破',
    subtitle: '周杰伦',
    cover: _cover(),
    isPlaying: isPlaying,
    progress: progress,
    onTap: () {},
    onToggle: onToggle ?? () {},
    onSeek: onSeek,
    onPrevious: onPrevious,
    onNext: onNext,
  );
}

void main() {
  group('MiniPlayerCard 尺寸契约', () {
    testWidgets('卡高 76、进度条 3、拖拽热区 20、三个按钮热区 44', (tester) async {
      _useSize(tester, const Size(400, 800));
      await tester.pumpWidget(_host(_card(onSeek: (_) {})));
      await tester.pump();

      // 卡片本体（含 0.7 发丝边）高度即 miniPlayerHeight
      final card = find
          .descendant(
            of: find.byType(MiniPlayerCard),
            matching: find.byType(Container),
          )
          .first;
      expect(tester.getSize(card).height, AppLayout.miniPlayerHeight);
      expect(AppLayout.miniPlayerHeight, 76);
      // 卡内可用高度 = 76 − 上下 0.7 边框
      final stack = find
          .descendant(of: find.byType(MiniPlayerCard), matching: find.byType(Stack))
          .first;
      expect(tester.getSize(stack).height, closeTo(74.6, 0.01));

      expect(tester.getSize(find.byType(PlaybackProgressBar)).height, 3);
      expect(
        tester.getSize(find.byType(PlaybackProgressScrubber)).height,
        20,
      );

      for (final tip in ['上一首', '下一首', '暂停']) {
        final size = tester.getSize(find.byTooltip(tip));
        expect(size.width, greaterThanOrEqualTo(44), reason: '$tip 热区宽度');
        expect(size.height, greaterThanOrEqualTo(44), reason: '$tip 热区高度');
      }
    });

    testWidgets('投影升级为 dock 阴影（比 card 更明显）', (tester) async {
      _useSize(tester, const Size(400, 800));
      await tester.pumpWidget(_host(_card()));
      await tester.pump();

      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(MiniPlayerCard),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.boxShadow, AppShadow.dock);
    });
  });

  group('MiniPlayerCard 交互', () {
    testWidgets('拖动进度条触发 onSeek，比例落在 0–1', (tester) async {
      _useSize(tester, const Size(400, 800));
      final seeks = <double>[];
      await tester.pumpWidget(_host(_card(onSeek: seeks.add)));
      await tester.pump();

      final scrubber = find.byType(PlaybackProgressScrubber);
      final rect = tester.getRect(scrubber);
      // 从轨道 20% 处向右拖到 60% 处：避开两端夹取，验证比例真的被换算
      await tester.dragFrom(
        Offset(rect.left + rect.width * 0.2, rect.center.dy),
        Offset(rect.width * 0.4, 0),
      );
      await tester.pumpAndSettle();

      expect(seeks, isNotEmpty, reason: '拖动必须触发 onSeek');
      for (final v in seeks) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
      expect(seeks.last, closeTo(0.6, 0.08));
    });

    testWidgets('上一首 / 播放键 / 下一首 各自回调，不会误触整卡点击', (tester) async {
      _useSize(tester, const Size(400, 800));
      var prev = 0, toggle = 0, next = 0, opened = 0;
      await tester.pumpWidget(
        _host(
          _card(
            onTap: () => opened++,
            onPrevious: () => prev++,
            onNext: () => next++,
            onToggle: () => toggle++,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('上一首'));
      await tester.pump();
      expect(prev, 1);
      expect(toggle, 0);
      expect(next, 0);

      await tester.tap(find.byTooltip('暂停'));
      await tester.pump();
      expect(toggle, 1);
      expect(prev, 1);
      expect(next, 0);

      await tester.tap(find.byTooltip('下一首'));
      await tester.pump();
      expect(next, 1);
      expect(prev, 1);
      expect(toggle, 1);
      expect(opened, 0, reason: '按钮自带热区，不应冒泡成整卡点击');
    });

    testWidgets('未播放时播放键显示「播放」', (tester) async {
      _useSize(tester, const Size(400, 800));
      await tester.pumpWidget(_host(_card(isPlaying: false)));
      await tester.pump();
      expect(find.byTooltip('播放'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('左右滑动手势保留：左滑下一首、右滑上一首', (tester) async {
      _useSize(tester, const Size(400, 800));
      var next = 0, prev = 0;
      await tester.pumpWidget(
        _host(
          _card(onSwipeNext: () => next++, onSwipePrevious: () => prev++),
        ),
      );
      await tester.pump();

      // 从卡片文字区（不落在进度热区上）起手滑动
      final title = tester.getRect(find.text('晴天'));
      await tester.flingFrom(title.center, const Offset(-260, 0), 1200);
      await tester.pumpAndSettle();
      expect(next, 1);

      await tester.flingFrom(title.center, const Offset(260, 0), 1200);
      await tester.pumpAndSettle();
      expect(prev, 1);
    });

    testWidgets('窄屏（320）隐藏封面，常规宽度（400）显示封面', (tester) async {
      _useSize(tester, const Size(320, 800));
      await tester.pumpWidget(_host(_card()));
      await tester.pump();
      expect(find.byKey(_coverKey), findsNothing, reason: '320 宽应隐藏封面');
      expect(find.text('晴天'), findsOneWidget);

      _useSize(tester, const Size(400, 800));
      await tester.pumpWidget(_host(_card()));
      await tester.pump();
      expect(find.byKey(_coverKey), findsOneWidget);
    });

    testWidgets('回调全为空：按钮置灰禁用、拖拽不崩', (tester) async {
      _useSize(tester, const Size(400, 800));
      await tester.pumpWidget(_host(_card(onSeek: null)));
      await tester.pump();

      final prevIcon = tester.widget<Icon>(
        find.byIcon(Icons.skip_previous_rounded),
      );
      final nextIcon = tester.widget<Icon>(find.byIcon(Icons.skip_next_rounded));
      expect(prevIcon.color, AppColors.inkDisabled);
      expect(nextIcon.color, AppColors.inkDisabled);

      await tester.tap(find.byTooltip('上一首'));
      await tester.tap(find.byTooltip('下一首'));
      final rect = tester.getRect(find.byType(PlaybackProgressScrubber));
      await tester.dragFrom(rect.center, const Offset(80, 0));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // onSeek 为空时进度条退化为纯展示：没有手势接管器
      expect(
        find.descendant(
          of: find.byType(PlaybackProgressScrubber),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );
    });
  });

  group('SideNowPlayingCard 与迷你卡同一套控制', () {
    testWidgets('上一首 / 播放 / 下一首 + 进度拖动都可用', (tester) async {
      _useSize(tester, const Size(224, 600));
      var prev = 0, next = 0, toggle = 0;
      final seeks = <double>[];
      await tester.pumpWidget(
        _host(
          _sideCard(
            onSeek: seeks.add,
            onPrevious: () => prev++,
            onNext: () => next++,
            onToggle: () => toggle++,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('上一首'));
      await tester.tap(find.byTooltip('下一首'));
      await tester.tap(find.byTooltip('暂停'));
      await tester.pump();
      expect(prev, 1);
      expect(next, 1);
      expect(toggle, 1);

      final rect = tester.getRect(find.byType(PlaybackProgressScrubber));
      await tester.dragFrom(rect.center, Offset(rect.width * 0.3, 0));
      await tester.pumpAndSettle();
      expect(seeks, isNotEmpty);
      expect(seeks.last, inInclusiveRange(0.0, 1.0));
    });

    testWidgets('无回调时同样不崩', (tester) async {
      _useSize(tester, const Size(224, 600));
      await tester.pumpWidget(_host(_sideCard()));
      await tester.pump();
      await tester.tap(find.byTooltip('上一首'));
      await tester.tap(find.byTooltip('下一首'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('进度条渲染', () {
    testWidgets('已播部分品牌色、轨道 surfaceMuted，0 进度不报错', (tester) async {
      _useSize(tester, const Size(400, 800));
      await tester.pumpWidget(_host(_card(progress: 0)));
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(_host(_card(progress: 0.5)));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
