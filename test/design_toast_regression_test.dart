// 灰屏根因回归测试 —— DesignToast 的 root Overlay 条目。
//
// 【历史 Bug】用户实测「关闭音效选择面板后整屏灰屏约 1 秒」。
// 灰屏 = release 下 `RenderErrorBox`（0xF0C0C0C0，alpha 94% → 底层以极低对比度透出）。
// 【根因】旧 `DesignToast` 用裸 OverlayEntry，把**调用方 BuildContext** 闭包进
// `builder`，并在其中调用 `MediaQuery.of(context)`；当调用方（如音效底部弹窗）被销毁、
// 而该全屏 `Positioned.fill` 条目仍在 root Overlay 中存活时，随后**任意一次 root
// Overlay 重建**都会用已卸载的 context 再次执行 builder →
// `Null check operator used on a null value`（release 可见的运行时异常，非 assert）→
// 整屏灰框；2 秒定时器移除条目后自动恢复。时间特征（关闭后约 0.1~0.2s 出现、
// 约 1s 后自愈）与录屏完全吻合。
//
// 本文件用 widget test 确定性复现「关闭调用方后发生一次根 Overlay 重建」，
// 确保修复后不再抛异常。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/widgets/design_dialog.dart';

void main() {
  setUp(DesignToast.debugReset);

  /// 构建「可打开底部弹窗、并在弹窗内展示 DesignToast」的最小宿主。
  Widget host() {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Builder(builder: (openCtx) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton(
                  onPressed: () {
                    showModalBottomSheet<void>(
                      context: openCtx,
                      builder: (ctx) => Builder(builder: (inner) {
                        return SizedBox(
                          height: 200,
                          child: Column(children: [
                            ElevatedButton(
                              onPressed: () => DesignToast.show(inner, '来自弹窗'),
                              child: const Text('apply'),
                            ),
                            ElevatedButton(
                              onPressed: () => Navigator.pop(inner),
                              child: const Text('close'),
                            ),
                          ]),
                        );
                      }),
                    );
                  },
                  child: const Text('open'),
                ),
                ElevatedButton(
                  onPressed: () {
                    DesignToast.show(openCtx, 'A');
                    DesignToast.show(openCtx, 'B');
                  },
                  child: const Text('show-twice'),
                ),
                ElevatedButton(
                  onPressed: () => DesignToast.show(openCtx, 'once'),
                  child: const Text('show-once'),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }

  /// 推进超过 2 秒，让 Toast 定时器正常触发（避免用例结束时报「Timer 仍挂起」）。
  Future<void> settleToast(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
  }

  testWidgets('回归：弹窗内展示 Toast → 关闭弹窗 → 根 Overlay 重建不再抛异常（灰屏根因）',
      (tester) async {
    await tester.pumpWidget(host());

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('apply'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '关闭弹窗本身就不应抛异常');

    // 关键：模拟真实设备上弹窗关闭后发生的**任意一次根 Overlay 重建**。
    // 旧实现会在此处用已卸载的弹窗 context 调用 MediaQuery.of → 抛异常。
    final overlay = tester.state<OverlayState>(find.byType(Overlay).first);
    final dummy = OverlayEntry(builder: (_) => const SizedBox.shrink());
    overlay.insert(dummy);
    await tester.pump();

    expect(
      tester.takeException(),
      isNull,
      reason: '关闭调用方后，root Overlay 重建不得再执行失效 context 的 build（历史灰屏根因）',
    );

    dummy.remove();
    await settleToast(tester);
  });

  testWidgets('复用单条条目：连续 show 不叠加，仅展示最新文案', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('show-twice'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('B'), findsOneWidget, reason: '应展示最新文案且不叠加');
    expect(find.text('A'), findsNothing, reason: '不得叠加多条全屏 layer');

    await settleToast(tester);
    expect(find.text('B'), findsNothing, reason: '2 秒后应自动消失');
  });

  testWidgets('移除幂等：多次 show 后在 2 秒边界反复推进无异常', (tester) async {
    await tester.pumpWidget(host());

    await tester.tap(find.text('show-once'));
    await tester.pump();
    expect(find.text('once'), findsOneWidget);

    // 1 秒后再次 show：应复用条目并复位定时器（旧定时器不会提前移除新提示）
    await tester.tap(find.text('show-twice'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('B'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 越过新定时器边界
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('B'), findsNothing);
  });

  testWidgets('兜底：调用方已卸载时 show 静默失败，不抛异常', (tester) async {
    late BuildContext dead;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        dead = c;
        return const SizedBox();
      }),
    ));
    // 卸载该 context
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    DesignToast.show(dead, 'x');
    await tester.pump();
    expect(tester.takeException(), isNull, reason: 'Toast 在任何情况下都不得成为异常源');
    await settleToast(tester);
  });
}
