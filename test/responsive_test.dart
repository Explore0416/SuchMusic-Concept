// 响应式单一真源 `lib/utils/responsive.dart` 的取值契约测试。
//
// 覆盖任务指定的 8 个宽度（含竖/横形态）：
//   320 / 393 / 430 / 600 / 840 / 900 / 1200 / 1600 dp
// 断言：断点判定正确、尺寸**永不为负 / 永不越界**、随宽度**单调不跳变**。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/utils/responsive.dart';

void main() {
  // 竖屏形态（宽 < 高）
  const portrait = <Size>[
    Size(320, 800),
    Size(393, 852),
    Size(430, 932),
    Size(600, 960),
    Size(840, 1200),
  ];
  // 横 / 超宽形态（宽 >= 高）
  const landscape = <Size>[
    Size(900, 600),
    Size(1200, 800),
    Size(1600, 900),
  ];
  final all = <Size>[...portrait, ...landscape];

  group('断点判定 of()/isTablet()', () {
    test('320/393/430 → B1 手机竖屏', () {
      for (final s in portrait.take(3)) {
        expect(Responsive.of(s), AppBreakpoint.b1PhonePortrait, reason: '$s');
        expect(Responsive.isTablet(s), isFalse);
      }
    });

    test('600x960 / 840x1200 → B3 平板竖屏（最短边≥600）', () {
      expect(Responsive.of(const Size(600, 960)),
          AppBreakpoint.b3TabletPortrait);
      expect(Responsive.of(const Size(840, 1200)),
          AppBreakpoint.b3TabletPortrait);
      expect(Responsive.isTablet(const Size(600, 960)), isTrue);
    });

    test('900x600 → B4；1200x800 / 1600x900 → B5', () {
      expect(Responsive.of(const Size(900, 600)),
          AppBreakpoint.b4TabletLandscape);
      expect(Responsive.of(const Size(1200, 800)), AppBreakpoint.b5UltraWide);
      expect(Responsive.of(const Size(1600, 900)), AppBreakpoint.b5UltraWide);
    });

    test('手机横屏 852x393 → B2', () {
      expect(Responsive.of(const Size(852, 393)),
          AppBreakpoint.b2PhoneLandscape);
      expect(Responsive.isTablet(const Size(852, 393)), isFalse);
    });

    test('临界：599x900 → B1；600x600（正方形平板）→ B3', () {
      expect(Responsive.of(const Size(599, 900)),
          AppBreakpoint.b1PhonePortrait);
      expect(Responsive.of(const Size(600, 600)),
          AppBreakpoint.b3TabletPortrait);
    });
  });

  group('形态开关 showRail / isPlayerSplit / isGridHome', () {
    test('showRail：仅 B4/B5（竖屏一律用原版胶囊栏）', () {
      expect(Responsive.showRail(AppBreakpoint.b1PhonePortrait), isFalse);
      expect(Responsive.showRail(AppBreakpoint.b2PhoneLandscape), isFalse);
      expect(Responsive.showRail(AppBreakpoint.b3TabletPortrait), isFalse);
      expect(Responsive.showRail(AppBreakpoint.b4TabletLandscape), isTrue);
      expect(Responsive.showRail(AppBreakpoint.b5UltraWide), isTrue);
    });

    test('isPlayerSplit：仅 B2/B4/B5', () {
      expect(Responsive.isPlayerSplit(AppBreakpoint.b1PhonePortrait), isFalse);
      expect(Responsive.isPlayerSplit(AppBreakpoint.b2PhoneLandscape), isTrue);
      expect(Responsive.isPlayerSplit(AppBreakpoint.b3TabletPortrait), isFalse);
      expect(Responsive.isPlayerSplit(AppBreakpoint.b4TabletLandscape), isTrue);
      expect(Responsive.isPlayerSplit(AppBreakpoint.b5UltraWide), isTrue);
    });
  });

  group('尺寸取值：永不为负 / 永不越界', () {
    test('bottomBarWidth ∈ (0, 400]，且 430dp 处为 354.4', () {
      for (final s in all) {
        final v = Responsive.bottomBarWidth(s);
        expect(v, greaterThan(0), reason: '$s');
        expect(v, lessThanOrEqualTo(400), reason: '$s');
      }
      expect(Responsive.bottomBarWidth(const Size(430, 932)),
          closeTo(354.4, 0.001));
    });

    test('uiScale ∈ [0.7, 1.15]，430dp 处等于 1.0', () {
      for (final s in all) {
        final v = Responsive.uiScale(s);
        expect(v, inInclusiveRange(0.7, 1.15), reason: '$s');
      }
      expect(Responsive.uiScale(const Size(430, 932)), closeTo(1.0, 0.001));
    });

    test('dialogScale ∈ [0.8, 1.0]，360/393/430dp 与改造前 width/430 一致', () {
      for (final s in all) {
        final v = Responsive.dialogScale(s);
        expect(v, inInclusiveRange(0.8, 1.0), reason: '$s');
      }
      // 360/393/430 均在 [0.8,1.0] 内未被夹取 → 与旧 width/430 完全一致
      for (final w in [360.0, 393.0, 430.0]) {
        expect(Responsive.dialogScale(Size(w, 800)), closeTo(w / 430, 1e-9),
            reason: 'w=$w');
      }
    });

    test('gradientHeight ∈ [240, 520]', () {
      for (final s in all) {
        expect(Responsive.gradientHeight(s), inInclusiveRange(240.0, 520.0));
      }
    });

    test('coverSize：B1 == 屏宽-50（基线）；其余 ∈ [200, 420]', () {
      for (final s in all) {
        final bp = Responsive.of(s);
        final v = Responsive.coverSize(s, bp);
        expect(v, greaterThan(0), reason: '$s');
        if (bp == AppBreakpoint.b1PhonePortrait) {
          expect(v, closeTo(s.width - 50, 1e-9), reason: '$s');
        } else {
          expect(v, inInclusiveRange(200.0, 420.0), reason: '$s');
        }
      }
      // 改造前基线：430 竖屏封面 = 380
      expect(
          Responsive.coverSize(
              const Size(430, 932), AppBreakpoint.b1PhonePortrait),
          closeTo(380, 1e-9));
    });

    test('clampLyricFont 不超过 lyricFontMax', () {
      expect(Responsive.clampLyricFont(30), 30);
      expect(Responsive.clampLyricFont(100), Responsive.lyricFontMax);
    });
  });

  group('单调不跳变（宽度递增）', () {
    const widths = [320.0, 393.0, 430.0, 600.0, 840.0, 900.0, 1200.0, 1600.0];

    test('bottomBarWidth 数组等于期望值（非递减）', () {
      final got =
          widths.map((w) => Responsive.bottomBarWidth(Size(w, 900))).toList();
      const expected = [257.6, 321.84, 354.4, 400.0, 400.0, 400.0, 400.0, 400.0];
      for (var i = 0; i < got.length; i++) {
        expect(got[i], closeTo(expected[i], 1e-9), reason: 'w=${widths[i]}');
      }
      for (var i = 1; i < got.length; i++) {
        expect(got[i], greaterThanOrEqualTo(got[i - 1]));
      }
    });

    test('uiScale 数组等于期望值（非递减，右端封顶 1.15）', () {
      final got = widths.map((w) => Responsive.uiScale(Size(w, 900))).toList();
      for (final v in got) {
        expect(v, inInclusiveRange(0.7, 1.15));
      }
      for (var i = 1; i < got.length; i++) {
        expect(got[i], greaterThanOrEqualTo(got[i - 1]));
      }
      expect(got.last, closeTo(1.15, 1e-9));
    });
  });

  group('首页网格列数 homeGridColumns', () {
    test('手机恒为 1 列', () {
      for (final s in [const Size(320, 800), const Size(430, 932),
        const Size(599, 900), const Size(852, 393)]) {
        expect(Responsive.homeGridColumns(s), 1, reason: '$s');
      }
    });

    test('平板：≥900 → 3 列；[600,900) → 2 列（REQ-03 平板一律 ≥2 列）', () {
      // 600–719dp 亦须双列（原先误判为 1 列，本轮修复）
      expect(Responsive.homeGridColumns(const Size(600, 960)), 2);
      expect(Responsive.homeGridColumns(const Size(719, 1200)), 2);
      expect(Responsive.homeGridColumns(const Size(840, 1200)), 2);
      expect(Responsive.homeGridColumns(const Size(900, 600)), 3);
      expect(Responsive.homeGridColumns(const Size(1200, 800)), 3);
      expect(Responsive.homeGridColumns(const Size(1600, 900)), 3);
    });

    test('列数恒在 [1,3]，且随宽度非递减', () {
      var prev = 0;
      for (final w in [320.0, 600.0, 719.0, 720.0, 899.0, 900.0, 1600.0]) {
        final c = Responsive.homeGridColumns(Size(w, 1000));
        expect(c, inInclusiveRange(1, 3), reason: 'w=$w');
        expect(c, greaterThanOrEqualTo(prev), reason: 'w=$w');
        prev = c;
      }
    });
  });

  // ── 回归护栏（第 2 轮硬门槛）：430×932 竖屏基线不可漂移 ──────────
  group('430×932 竖屏基线护栏', () {
    const base = Size(430, 932);

    test('bottomBarWidth == 354.4', () {
      expect(Responsive.bottomBarWidth(base), closeTo(354.4, 1e-9));
    });

    test('coverSize(B1) == 380', () {
      expect(Responsive.of(base), AppBreakpoint.b1PhonePortrait);
      expect(Responsive.coverSize(base, AppBreakpoint.b1PhonePortrait),
          closeTo(380, 1e-9));
    });

    test('uiScale == 1.0', () {
      expect(Responsive.uiScale(base), closeTo(1.0, 1e-9));
    });

    test('dialogScale == 1.0', () {
      expect(Responsive.dialogScale(base), closeTo(1.0, 1e-9));
    });
  });

  group('底部导航宽度', () {
    test('平板 / 横屏固定 400，不随屏宽拉伸', () {
      expect(Responsive.bottomBarWidth(const Size(1024, 700)), 400);
      expect(Responsive.bottomBarWidth(const Size(1600, 900)), 400);
    });

    test('手机跟随屏宽并留边距', () {
      final w430 = Responsive.bottomBarWidth(const Size(430, 932));
      expect(w430, closeTo(354.4, 0.5));
      expect(w430, lessThanOrEqualTo(400));
    });

    test('窄屏不会超出屏幕宽度', () {
      for (final w in [320.0, 360.0, 393.0]) {
        final bar = Responsive.bottomBarWidth(Size(w, 800));
        expect(bar, lessThan(w), reason: '宽度 ${w.toInt()} 时底栏不得溢出');
      }
    });
  });
}
