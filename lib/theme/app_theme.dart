import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// 设计令牌（Design Tokens）
///
/// 全项目只在这里定义颜色、字号、间距、圆角与投影；业务代码引用语义令牌，
/// 不再散落 `Color(0xFF...)`。配色走「纸感暖白 + 墨黑 + 单一钴蓝强调」，
/// 中性色带统一暖调，避免纯黑纯灰带来的割裂感。
abstract final class AppColors {
  /// 页面画布：暖白纸感，比纯白柔和，让白色卡面浮起来
  static const canvas = Color(0xFFF7F7F5);

  /// 卡面 / 导航 / 弹层底色
  static const surface = Color(0xFFFFFFFF);

  /// 次级表面：搜索框、分段控件底、未选中块
  static const surfaceMuted = Color(0xFFF1F1ED);

  /// 主文字（墨）
  static const ink = Color(0xFF15171C);

  /// 次文字
  static const inkSecondary = Color(0xFF626873);

  /// 三级文字 / 占位
  static const inkTertiary = Color(0xFF9AA0A8);

  /// 极浅文字（禁用）
  static const inkDisabled = Color(0xFFC4C8CF);

  /// 0.5px 发丝线
  static const hairline = Color(0xFFECEBE6);

  /// 强调色：只在选中态、进度、关键动作上出现
  static const brand = Color(0xFF2F5BFF);

  /// 强调色浅底
  static const brandSoft = Color(0xFFEFF2FF);

  /// 喜欢 / 收藏
  static const rose = Color(0xFFF1546B);
  static const roseSoft = Color(0xFFFFF0F3);

  static const success = Color(0xFF16A34A);
  static const successSoft = Color(0xFFF0FDF4);
  static const warning = Color(0xFFEA580C);
  static const warningSoft = Color(0xFFFFF7ED);
  static const danger = Color(0xFFDC2626);
  static const dangerSoft = Color(0xFFFEF2F2);

  /// 深色播放页背景（不是纯黑）
  static const night = Color(0xFF101218);
}

/// 字号阶梯：全页最多四种（28 / 20 / 15 / 12）。
///
/// 层级优先用字重、灰阶与间距表达，不靠继续加字号。
abstract final class AppType {
  static const display = TextStyle(
    fontFamily: 'MiSans',
    fontSize: 28,
    height: 1.22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.6,
    color: AppColors.ink,
  );

  static const title = TextStyle(
    fontFamily: 'MiSans',
    fontSize: 20,
    height: 1.28,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    color: AppColors.ink,
  );

  static const body = TextStyle(
    fontFamily: 'MiSans',
    fontSize: 15,
    height: 1.36,
    fontWeight: FontWeight.w500,
    color: AppColors.ink,
  );

  static const caption = TextStyle(
    fontFamily: 'MiSans',
    fontSize: 12,
    height: 1.42,
    fontWeight: FontWeight.w400,
    color: AppColors.inkSecondary,
  );

  static const captionStrong = TextStyle(
    fontFamily: 'MiSans',
    fontSize: 12,
    height: 1.42,
    fontWeight: FontWeight.w600,
    color: AppColors.inkSecondary,
  );
}

/// 4 / 8 间距网格
abstract final class AppSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const xxxl = 32.0;

  /// 手机页面左右安全边距
  static const page = 20.0;
}

/// 圆角：按物理层级分配，不随手写数字
abstract final class AppRadius {
  static const row = 14.0;
  static const card = 20.0;
  static const hero = 26.0;
  static const sheet = 28.0;
  static const pill = 999.0;
}

/// 柔和弥散投影：只服务真实浮起层级（底栏、悬浮播放卡、弹层）
abstract final class AppShadow {
  static const dock = [
    BoxShadow(color: Color(0x0F15171C), blurRadius: 24, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x08000000), blurRadius: 4, offset: Offset(0, 1)),
  ];

  static const card = [
    BoxShadow(color: Color(0x0815171C), blurRadius: 12, offset: Offset(0, 4)),
  ];
}

/// 布局常量：底部「播放卡 + 导航坞」占用的高度。
///
/// 页面滚动内容统一留出这段空间，避免最后一行被底栏压住。
abstract final class AppLayout {
  static const dockHeight = 64.0;
  static const dockGap = 8.0;

  /// 迷你播放卡高度（1.4.0：60 → 76，为 3px 进度条与上下曲按钮让位）
  static const miniPlayerHeight = 76.0;

  /// 播放卡内进度条的拖拽热区高度（条本身 3px，热区 20px 便于手指命中）
  static const miniPlayerProgressHitHeight = 20.0;

  static const dockMargin = 16.0;

  /// 有播放内容时：导航坞 + 间距 + 播放卡 + 上下留白
  /// （1.4.0：168 → 184，随 [miniPlayerHeight] 同步 +16）
  static const bottomInsetWithPlayer = 184.0;

  /// 无播放内容时：只有导航坞
  static const bottomInset = 104.0;
}

/// 全局主题：把 Material 组件收敛到同一套令牌，避免各页各写一套样式。
abstract final class AppTheme {
  static ThemeData light() {
    const scheme = ColorScheme(
      brightness: Brightness.light,
      primary: AppColors.brand,
      onPrimary: Colors.white,
      primaryContainer: AppColors.brandSoft,
      onPrimaryContainer: AppColors.brand,
      secondary: AppColors.ink,
      onSecondary: Colors.white,
      secondaryContainer: AppColors.surfaceMuted,
      onSecondaryContainer: AppColors.ink,
      error: AppColors.danger,
      onError: Colors.white,
      surface: AppColors.surface,
      onSurface: AppColors.ink,
      onSurfaceVariant: AppColors.inkSecondary,
      surfaceContainerHighest: AppColors.surfaceMuted,
      outline: AppColors.hairline,
      outlineVariant: AppColors.hairline,
      shadow: Color(0x1415171C),
      scrim: Color(0x6615171C),
      inverseSurface: AppColors.ink,
      onInverseSurface: Colors.white,
      inversePrimary: Color(0xFF9DB2FF),
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'MiSans',
    );

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.canvas,
      canvasColor: AppColors.canvas,
      splashFactory: InkSparkle.splashFactory,
      textTheme: base.textTheme.copyWith(
        displaySmall: AppType.display,
        titleLarge: AppType.title,
        titleMedium: AppType.body.copyWith(fontWeight: FontWeight.w600),
        bodyLarge: AppType.body,
        bodyMedium: AppType.caption.copyWith(color: AppColors.ink),
        bodySmall: AppType.caption,
        labelLarge: AppType.body.copyWith(fontWeight: FontWeight.w600),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: AppSpace.page,
        titleTextStyle: AppType.title,
        iconTheme: IconThemeData(color: AppColors.ink),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.hairline,
        thickness: 0.7,
        space: 0.7,
      ),
      iconTheme: const IconThemeData(color: AppColors.ink, size: 22),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.ink,
          foregroundColor: Colors.white,
          minimumSize: const Size(64, 50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.row),
          ),
          textStyle: const TextStyle(
            fontFamily: 'MiSans',
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.brand,
          textStyle: const TextStyle(
            fontFamily: 'MiSans',
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceMuted,
        hintStyle: AppType.caption.copyWith(color: AppColors.inkTertiary),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpace.lg,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.row),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.row),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.row),
          borderSide: const BorderSide(color: AppColors.brand, width: 1),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: Color(0x6615171C),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.sheet),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.ink,
        contentTextStyle: AppType.body.copyWith(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.row),
        ),
        elevation: 0,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.brand,
        linearTrackColor: AppColors.surfaceMuted,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : AppColors.surface,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.ink
              : AppColors.surfaceMuted,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.ink
              : AppColors.hairline,
        ),
      ),
      // Android 走预测性返回：手势刚开始就能看到上一级页面，
      // 页面同时缩放淡出（系统级「缩到角落」预览）。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}
