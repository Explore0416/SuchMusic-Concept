import 'package:flutter/material.dart';

import '../models/song_model.dart';
import '../theme/app_theme.dart';
import 'app_ui.dart';

/// 首页封面构建器：由页面提供取图实现（列表组件本身不碰网络）。
typedef SectionCoverBuilder = Widget Function(SongModel song, double side);

/// 首页区块之间的呼吸间距（1.4.0：24 → 36）。
///
/// 三个区块形状已经不同，间距必须统一成同一个值，否则「差异」会退化成
/// 「排版没对齐」。常量在这里单点定义，页面与测试共用同一真源。
class HomeSectionSpacer extends StatelessWidget {
  const HomeSectionSpacer({super.key});

  /// 区块间距（页面在所有区块之间统一使用）
  static const double height = 36;

  @override
  Widget build(BuildContext context) {
    return const SizedBox(height: height);
  }
}

/// 常驻搜索框：首页固定在 header 下方的一整条可点区域（不是图标按钮）。
///
/// 用户反馈「搜索按钮不明显、还要手动跳界面」，因此把它做成一个**看起来就是
/// 输入框**的入口：高 44、浅底、圆角 14，整框可点，点击进入搜索页。
class HomeSearchEntry extends StatelessWidget {
  const HomeSearchEntry({
    super.key,
    required this.onTap,
    this.placeholder = '搜索歌曲、歌手、歌单',
  });

  final VoidCallback onTap;
  final String placeholder;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadius.row);
    return SizedBox(
      height: 44,
      child: Material(
        color: AppColors.surfaceMuted,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                const Icon(
                  Icons.search_rounded,
                  size: 18,
                  color: AppColors.inkTertiary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    placeholder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.body.copyWith(
                      color: AppColors.inkTertiary,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「猜你想听」：横向大卡轨道（卡宽 148，一行一屏放 2 张多一点）。
class PickRail extends StatelessWidget {
  const PickRail({
    super.key,
    required this.songs,
    required this.coverOf,
    required this.onSongTap,
    this.loading = false,
  });

  final List<SongModel> songs;
  final SectionCoverBuilder coverOf;
  final ValueChanged<SongModel> onSongTap;
  final bool loading;

  /// 卡片之间的间距（与页面 20 边距配合：一屏约 2.2 张卡）
  static const double gap = AppSpace.md;

  @override
  Widget build(BuildContext context) {
    if (loading) return const PickRailSkeleton();
    if (songs.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < songs.length; i++) ...[
            if (i > 0) const SizedBox(width: gap),
            PickRailCard(
              song: songs[i],
              cover: coverOf(songs[i], PickRailCard.side),
              onTap: () => onSongTap(songs[i]),
            ),
          ],
        ],
      ),
    );
  }
}

/// 横向大卡：148 正方形封面（圆角 20）+ 歌名两行 + 艺人一行。
class PickRailCard extends StatelessWidget {
  const PickRailCard({
    super.key,
    required this.song,
    required this.cover,
    required this.onTap,
  });

  final SongModel song;

  /// 已按 [side] 构建好的封面（由页面取图）
  final Widget cover;
  final VoidCallback onTap;

  /// 卡片宽度 = 封面边长
  static const double side = 148;

  /// 歌名区固定两行高度：单行歌名也占两行，保证同排艺人名基线一致
  static const double _titleHeight = 42;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: side,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.card),
              child: SizedBox(width: side, height: side, child: cover),
            ),
            const SizedBox(height: AppSpace.sm),
            SizedBox(
              height: _titleHeight,
              child: Text(
                song.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppType.body.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.36,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              song.artist.isEmpty ? '未知歌手' : song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.caption.copyWith(color: AppColors.inkTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

/// 横向大卡骨架：与 [PickRailCard] 同形状（148 封面 + 两行文字条）。
class PickRailSkeleton extends StatelessWidget {
  const PickRailSkeleton({super.key, this.count = 3});

  final int count;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const SizedBox(width: PickRail.gap),
            const Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppSkeleton(
                  width: PickRailCard.side,
                  height: PickRailCard.side,
                  radius: AppRadius.card,
                ),
                SizedBox(height: AppSpace.sm),
                AppSkeleton(width: 118, height: 12, radius: 4),
                SizedBox(height: 6),
                AppSkeleton(width: 72, height: 10, radius: 4),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 「每日推荐」：两列网格（一屏 3 行 6 首），密度低于横卡、高于排行。
class DailyGrid extends StatelessWidget {
  const DailyGrid({
    super.key,
    required this.songs,
    required this.coverOf,
    required this.onSongTap,
    this.loading = false,
    this.maxItems = 6,
  });

  final List<SongModel> songs;
  final SectionCoverBuilder coverOf;
  final ValueChanged<SongModel> onSongTap;
  final bool loading;

  /// 首页只铺 6 首，剩下的交给右上角「全部」入口
  final int maxItems;

  static const int columns = 2;
  static const double columnGap = AppSpace.md;
  static const double rowGap = AppSpace.xl;

  /// 封面之外的文字高度：8(间距) + 歌名 20.4 + 2 + 艺人 17.04 → 留 52 的余量
  static const double _textBlockHeight = 52;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final itemWidth = _itemWidthOf(constraints.maxWidth);
            return GridView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: _delegateOf(itemWidth),
              itemCount: maxItems,
              itemBuilder: (_, _) => DailyGridSkeletonCard(width: itemWidth),
            );
          },
        ),
      );
    }
    if (songs.isEmpty) return const SizedBox.shrink();

    final items = songs.take(maxItems).toList(); // 只展示前 6 首
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final itemWidth = _itemWidthOf(constraints.maxWidth);
          return GridView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: _delegateOf(itemWidth),
            itemCount: items.length,
            itemBuilder: (_, i) => DailyGridCard(
              song: items[i],
              cover: coverOf(items[i], itemWidth),
              onTap: () => onSongTap(items[i]),
            ),
          );
        },
      ),
    );
  }

  static double _itemWidthOf(double maxWidth) =>
      (maxWidth - columnGap * (columns - 1)) / columns;

  static SliverGridDelegateWithFixedCrossAxisCount _delegateOf(
    double itemWidth,
  ) {
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: columnGap,
      mainAxisSpacing: rowGap,
      mainAxisExtent: itemWidth + _textBlockHeight,
    );
  }
}

/// 网格卡：正方形封面（圆角 16）+ 歌名一行 + 艺人一行。
class DailyGridCard extends StatelessWidget {
  const DailyGridCard({
    super.key,
    required this.song,
    required this.cover,
    required this.onTap,
  });

  final SongModel song;

  /// 已按网格列宽构建好的正方形封面（由页面取图）
  final Widget cover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.row + 2),
            child: AspectRatio(aspectRatio: 1, child: cover),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            song.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.body.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            song.artist.isEmpty ? '未知歌手' : song.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.caption.copyWith(color: AppColors.inkTertiary),
          ),
        ],
      ),
    );
  }
}

/// 网格骨架：正方形封面块 + 一行文字条，形状与 [DailyGridCard] 一致。
class DailyGridSkeletonCard extends StatelessWidget {
  const DailyGridSkeletonCard({super.key, required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: AppSkeleton(
            width: width,
            height: width,
            radius: AppRadius.row + 2,
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        const AppSkeleton(width: 96, height: 12, radius: 4),
        const SizedBox(height: 6),
        const AppSkeleton(width: 60, height: 10, radius: 4),
      ],
    );
  }
}

/// 「热歌推荐」：紧凑排行列表（前 5 首，行高 56，序号 + 小封面 + 单行信息）。
class HotRankList extends StatelessWidget {
  const HotRankList({
    super.key,
    required this.songs,
    required this.coverOf,
    required this.onSongTap,
    this.loading = false,
    this.maxItems = 5,
  });

  final List<SongModel> songs;
  final SectionCoverBuilder coverOf;
  final ValueChanged<SongModel> onSongTap;
  final bool loading;

  /// 首页只铺 5 首，暴露「这是一个榜单」而不是一屏歌
  final int maxItems;

  /// 小封面边长
  static const double coverSide = 40;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: AppSpace.page),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HotRankSkeletonRow(),
            HotRankSkeletonRow(),
            HotRankSkeletonRow(),
            HotRankSkeletonRow(),
            HotRankSkeletonRow(),
          ],
        ),
      );
    }
    if (songs.isEmpty) return const SizedBox.shrink();

    final items = songs.take(maxItems).toList(); // 前 5 首
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < items.length; i++)
            HotRankRow(
              index: i,
              song: items[i],
              cover: coverOf(items[i], coverSide),
              onTap: () => onSongTap(items[i]),
              showDivider: i != items.length - 1,
            ),
        ],
      ),
    );
  }
}

/// 排行行：高 56，左起序号（28 宽）/ 封面 40（圆角 10）/ 歌名 + 艺人。
class HotRankRow extends StatelessWidget {
  const HotRankRow({
    super.key,
    required this.index,
    required this.song,
    required this.cover,
    required this.onTap,
    this.showDivider = true,
  });

  /// 0 基序号，渲染成 01–05
  final int index;
  final SongModel song;

  /// 已按 [HotRankList.coverSide] 构建好的小封面（由页面取图）
  final Widget cover;
  final VoidCallback onTap;
  final bool showDivider;

  static const double height = 56;
  static const double indexWidth = 28;

  /// 行间发丝线左缩进 = 序号 28 + 间距 8 + 封面 40 = 76，与封面右缘对齐。
  ///
  /// 规格文档里写的 68 是笔误（少算了序号列宽与间距里的一段），以此值为准。
  static const double dividerIndent = indexWidth + AppSpace.sm + HotRankList.coverSide;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            splashFactory: NoSplash.splashFactory,
            highlightColor: AppColors.surfaceMuted,
            overlayColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.pressed)
                  ? AppColors.surfaceMuted
                  : null,
            ),
            child: SizedBox(
              height: height,
              child: Row(
                children: [
                  SizedBox(
                    width: indexWidth,
                    child: Text(
                      (index + 1).toString().padLeft(2, '0'),
                      style: AppType.caption.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.inkTertiary,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: HotRankList.coverSide,
                      height: HotRankList.coverSide,
                      child: cover,
                    ),
                  ),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.body.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          song.artist.isEmpty ? '未知歌手' : song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.caption.copyWith(
                            color: AppColors.inkTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (showDivider) const AppHairline(indent: dividerIndent),
      ],
    );
  }
}

/// 排行骨架：与 [HotRankRow] 同高的列表条，形状与横卡 / 网格明显不同。
class HotRankSkeletonRow extends StatelessWidget {
  const HotRankSkeletonRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: HotRankRow.height,
          child: Row(
            children: [
              const SizedBox(
                width: HotRankRow.indexWidth,
                child: AppSkeleton(width: 18, height: 10, radius: 3),
              ),
              const SizedBox(width: AppSpace.sm),
              AppSkeleton(
                width: HotRankList.coverSide,
                height: HotRankList.coverSide,
                radius: 10,
              ),
              const SizedBox(width: AppSpace.md),
              const Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppSkeleton(width: 140, height: 12, radius: 4),
                    SizedBox(height: 6),
                    AppSkeleton(width: 72, height: 10, radius: 4),
                  ],
                ),
              ),
            ],
          ),
        ),
        const AppHairline(indent: HotRankRow.dividerIndent),
      ],
    );
  }
}
