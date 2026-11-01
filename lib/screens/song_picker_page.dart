import 'package:flutter/material.dart';

import '../models/song_model.dart';
import '../services/audio_player_service.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../widgets/app_ui.dart';

/// 从当前播放队列里多选歌曲。
///
/// 返回选中的歌曲（取消则返回 null）。
class SongPickerPage extends StatefulWidget {
  const SongPickerPage({super.key, this.title = '添加歌曲'});

  final String title;

  @override
  State<SongPickerPage> createState() => _SongPickerPageState();
}

class _SongPickerPageState extends State<SongPickerPage> {
  late final List<SongModel> _songs = AudioPlayerService().playlist;
  final Set<String> _selected = <String>{};

  void _toggle(SongModel song) {
    setState(() {
      if (!_selected.remove(song.id)) _selected.add(song.id);
    });
  }

  void _confirm() {
    if (_selected.isEmpty) return;
    Navigator.pop(
      context,
      _songs.where((x) => _selected.contains(x.id)).toList(),
    );
  }

  /// 全选 / 取消全选：长列表里逐条点是负担
  void _toggleAll() {
    setState(() {
      if (_selected.length == _songs.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_songs.map((s) => s.id));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final allSelected = _songs.isNotEmpty && _selected.length == _songs.length;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        bottom: false,
        child: ResponsiveContent(
          child: Column(
            children: [
              _buildHeader(allSelected),
              Expanded(
                child: _songs.isEmpty
                    ? const AppEmptyState(
                        icon: Icons.queue_music_rounded,
                        title: '当前播放列表是空的',
                        message: '先播放一些歌，再回来把它们加进歌单',
                      )
                    : _buildList(),
              ),
              if (_songs.isNotEmpty) _buildBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(bool allSelected) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.sm,
        AppSpace.sm,
        AppSpace.page,
        AppSpace.xs,
      ),
      child: Row(
        children: [
          AppIconButton(
            icon: Icons.arrow_back_ios_new_rounded,
            iconSize: 18,
            tooltip: '返回',
            onTap: () => Navigator.maybePop(context),
          ),
          const SizedBox(width: AppSpace.xs),
          Expanded(
            child: Text(
              widget.title,
              style: AppType.display,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_songs.isNotEmpty)
            TextButton(
              onPressed: _toggleAll,
              child: Text(allSelected ? '取消全选' : '全选'),
            ),
        ],
      ),
    );
  }

  Widget _buildList() {
    final rows = <Widget>[];
    for (var i = 0; i < _songs.length; i++) {
      if (i > 0) {
        rows.add(const AppHairline(indent: 44, endIndent: AppSpace.lg));
      }
      rows.add(_buildRow(_songs[i]));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.xs,
        AppSpace.page,
        AppSpace.xxl,
      ),
      children: [
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(children: rows),
        ),
      ],
    );
  }

  Widget _buildRow(SongModel song) {
    final checked = _selected.contains(song.id);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _toggle(song),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg,
            vertical: 12,
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: checked ? AppColors.brand : Colors.transparent,
                  border: Border.all(
                    color: checked ? AppColors.brand : AppColors.inkDisabled,
                    width: checked ? 0 : 1.4,
                  ),
                ),
                child: checked
                    ? const Icon(
                        Icons.check_rounded,
                        size: 15,
                        color: Colors.white,
                      )
                    : null,
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      song.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.body,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.md,
        AppSpace.page,
        AppSpace.lg,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.hairline, width: 0.7)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton(
            onPressed: _selected.isEmpty ? null : _confirm,
            style: FilledButton.styleFrom(
              disabledBackgroundColor: AppColors.surfaceMuted,
              disabledForegroundColor: AppColors.inkTertiary,
            ),
            child: Text(
              _selected.isEmpty ? '请选择歌曲' : '添加 ${_selected.length} 首',
            ),
          ),
        ),
      ),
    );
  }
}
