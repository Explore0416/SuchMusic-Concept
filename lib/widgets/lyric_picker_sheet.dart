import 'dart:async';

import 'package:flutter/material.dart';

import '../models/song_model.dart';
import '../services/local_lyric_service.dart';
import '../services/sources/source_manager.dart';

/// 弹出「选择歌词」底部弹窗：按歌名搜索 → 从结果里挑一条 → 用它的歌词。
///
/// 适用场景：本地音乐或某些曲目识别不到歌词时，让用户手动指定一条歌词。
///
/// 返回：成功选中并写入歌词 → `true`；用户取消 / 直接关闭 → `false`。
/// 所有网络调用已在内部 try/catch 兜底，绝不向调用方抛异常。
Future<bool> showLyricPickerSheet(BuildContext context, SongModel song) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      // 键盘弹起时把弹层整体上推，避免遮挡搜索框
      final bottom = MediaQuery.of(ctx).viewInsets.bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: LyricPickerSheet(song: song),
      );
    },
  );
  return result ?? false;
}

/// 「选择歌词」面板：StatelessWidget 外壳 + 内部 State 管理搜索/结果/取词状态。
class LyricPickerSheet extends StatelessWidget {
  const LyricPickerSheet({super.key, required this.song});

  /// 待指定歌词的原始歌曲（用于搜索默认关键词 + 写入歌词映射）
  final SongModel song;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: _LyricPickerBody(song: song),
    );
  }
}

class _LyricPickerBody extends StatefulWidget {
  const _LyricPickerBody({required this.song});

  final SongModel song;

  @override
  State<_LyricPickerBody> createState() => _LyricPickerBodyState();
}

class _LyricPickerBodyState extends State<_LyricPickerBody> {
  // 项目主色 / 副标题灰
  static const Color _accent = Color(0xFF2F84FE);
  static const Color _sub = Color(0xFF838383);
  static const Color _divider = Color(0xFFEEEEEE);

  /// 搜索输入防抖时长
  static const Duration _debounce = Duration(milliseconds: 250);

  late final TextEditingController _controller;
  Timer? _timer;

  List<SongModel> _results = const [];
  bool _loading = false;

  /// 取词失败时展示的一行灰色提示；为空表示不展示
  String? _hint;

  /// 正在取词，避免重复点击
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    // 默认填入歌名，用户可自行修改
    _controller = TextEditingController(text: widget.song.name);
    _controller.addListener(_onChanged);
    // 首次进入即按歌名搜索一次
    _search(widget.song.name);
  }

  @override
  void dispose() {
    // 组件销毁时取消定时器，避免回调打到已卸载的 State
    _timer?.cancel();
    _timer = null;
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    _timer?.cancel();
    final keyword = _controller.text.trim();
    _timer = Timer(_debounce, () => _search(keyword));
  }

  /// 搜索：失败一律降级为空结果，不抛异常
  Future<void> _search(String keyword) async {
    if (keyword.isEmpty) {
      if (!mounted) return;
      setState(() {
        _results = const [];
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _hint = null;
    });
    List<SongModel> list;
    try {
      list = await SourceManager().source.search(keyword);
    } catch (_) {
      list = const [];
    }
    if (!mounted) return;
    setState(() {
      _results = list;
      _loading = false;
    });
  }

  /// 选中一条结果：取歌词 → 写入本地映射 → 关闭弹层返回 true；
  /// 取不到歌词时只提示，不关闭弹层。
  Future<void> _pick(SongModel picked) async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _hint = null;
    });
    String? lrc;
    try {
      lrc = await SourceManager().source.getLyrics(picked);
    } catch (_) {
      lrc = null;
    }
    if (!mounted) return;
    if (lrc == null || lrc.trim().isEmpty) {
      setState(() {
        _picking = false;
        _hint = '这首歌也没有歌词，换一首试试';
      });
      return;
    }
    try {
      await LocalLyricService().set(widget.song.id, lrc);
    } catch (_) {
      // 写盘失败不阻断：最坏只是本次未持久化
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.62;
    return SizedBox(
      height: height,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(),
          const Divider(height: 1, color: _divider),
          _buildSearchField(),
          _buildHint(),
          Flexible(child: _buildBody()),
        ],
      ),
    );
  }

  /// 顶部：标题 + 副标题 + 关闭按钮
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '选择歌词',
                  style: TextStyle(
                    color: Colors.black87,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '为《${widget.song.name}》选择歌词',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _sub, fontSize: 12.5),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => Navigator.of(context).pop(false),
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close, color: Colors.black54, size: 22),
            ),
          ),
        ],
      ),
    );
  }

  /// 搜索框：默认歌名，可修改，250ms 防抖
  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF5F6F8),
          borderRadius: BorderRadius.circular(12),
        ),
        child: TextField(
          controller: _controller,
          textInputAction: TextInputAction.search,
          onSubmitted: (value) => _search(value.trim()),
          style: const TextStyle(color: Colors.black87, fontSize: 14.5),
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            prefixIcon: Icon(Icons.search, color: _sub, size: 20),
            hintText: '输入歌名搜索',
            hintStyle: TextStyle(color: _sub, fontSize: 14),
          ),
        ),
      ),
    );
  }

  /// 一行灰色提示（取词失败时展示）
  Widget _buildHint() {
    final hint = _hint;
    if (hint == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: _sub, size: 15),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              hint,
              style: const TextStyle(color: _sub, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }

  /// 中部：loading / 空态 / 结果列表
  Widget _buildBody() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: _accent,
            ),
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 28, 16, 28),
        child: Center(
          child: Text(
            '没有找到相关歌曲',
            style: TextStyle(color: _sub, fontSize: 13.5),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: _results.length,
      itemBuilder: (ctx, index) => _buildItem(_results[index]),
    );
  }

  /// 单条结果：歌名（黑 87）+ 歌手（灰）
  Widget _buildItem(SongModel item) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      title: Text(
        item.name.isEmpty ? '未知歌曲' : item.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.black87,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: (item.artist.isEmpty && item.album.isEmpty)
          ? null
          : Text(
              item.artist.isEmpty ? item.album : item.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _sub, fontSize: 12.5),
            ),
      onTap: _picking ? null : () => _pick(item),
    );
  }
}
