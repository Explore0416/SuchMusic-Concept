import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../models/song_model.dart';
import '../services/music_api_service.dart';
import '../services/audio_player_service.dart';
import '../services/search_history_service.dart';
import '../services/play_context_service.dart';
import '../services/sources/source_manager.dart';
import '../services/app_init.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../utils/player_route.dart';
import '../widgets/app_ui.dart';

/// 搜索页：输入即联想，提交即结果。
///
/// 四种状态各有承载：初始（历史 + 热搜）/ 联想 / 加载（骨架）/ 结果与空结果。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _searchController = TextEditingController();
  final MusicApiService _apiService = MusicApiService();
  final AudioPlayerService _audioPlayer = AudioPlayerService();
  final SearchHistoryService _historyService = SearchHistoryService();
  final FocusNode _focusNode = FocusNode();

  bool _isLoading = false;
  List<SongModel> _searchResults = [];
  List<String> _hotKeys = [];
  List<String> _suggestions = [];
  List<String> _searchHistory = [];
  String _errorMessage = '';

  /// 已提交的关键词，用于在结果里高亮
  String _submittedQuery = '';

  StreamSubscription<SongSource>? _sourceSub;
  Timer? _suggestDebounce;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadHotKeys();
    _searchController.addListener(_onSearchTextChanged);
    // 音源切换后刷新热搜并清空旧结果
    _sourceSub = SourceManager().onSourceChanged.listen((_) {
      if (!mounted) return;
      _suggestDebounce?.cancel();
      setState(() {
        _searchResults = [];
        _suggestions = [];
        _errorMessage = '';
      });
      _loadHotKeys();
    });
  }

  Future<void> _loadHistory() async {
    await _historyService.init();
    if (mounted) {
      setState(() {
        _searchHistory = _historyService.history;
      });
    }
  }

  Future<void> _loadHotKeys() async {
    await ensureInitialized;
    // 当前音源的热搜；为空时兜底网易云热搜
    var keys = await SourceManager().source.hotSearch();
    if (keys.isEmpty) {
      keys = await _apiService.getHotSearchKeys();
    }
    if (mounted) {
      setState(() {
        _hotKeys = keys;
      });
    }
  }

  void _onSearchTextChanged() {
    final query = _searchController.text.trim();
    _suggestDebounce?.cancel();
    if (query.isEmpty) {
      setState(() {
        _suggestions = [];
        _searchResults = [];
        _errorMessage = '';
      });
      return;
    }
    setState(() {
      _searchResults = [];
      _errorMessage = '';
    });
    // 输入防抖：停止输入 250ms 后再请求联想，避免逐字高频打接口
    _suggestDebounce = Timer(
      const Duration(milliseconds: 250),
      () => _loadSuggestions(query),
    );
  }

  Future<void> _loadSuggestions(String query) async {
    // 优先当前音源的联想；为空时回退网易云，保证任意音源下都有输入提示
    var suggestions = <String>[];
    try {
      suggestions = await SourceManager().source.searchSuggest(query);
    } catch (_) {
      suggestions = <String>[];
    }
    if (suggestions.isEmpty &&
        SourceManager().currentSource != SongSource.netease) {
      suggestions = await _apiService.searchSuggest(query);
    }
    if (mounted && _searchController.text.trim() == query) {
      setState(() {
        _suggestions = suggestions;
      });
    }
  }

  void _submitKeyword(String keyword) {
    _searchController.text = keyword;
    _searchController.selection = TextSelection.fromPosition(
      TextPosition(offset: keyword.length),
    );
    _performSearch();
  }

  Future<void> _performSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;

    _focusNode.unfocus();
    await _historyService.add(query);
    if (mounted) {
      setState(() {
        _searchHistory = _historyService.history;
      });
    }
    setState(() {
      _isLoading = true;
      _errorMessage = '';
      _searchResults = [];
      _suggestions = [];
      _submittedQuery = query;
    });

    try {
      // 走当前音源搜索（网易云 / 酷狗概念版）
      final results = await SourceManager().source.search(query);
      if (mounted) {
        setState(() {
          _searchResults = results;
          _isLoading = false;
          if (results.isEmpty) {
            _errorMessage = '未找到相关歌曲';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage =
              '搜索失败: ${e.toString().replaceFirst('Exception: ', '')}';
        });
      }
    }
  }

  Future<void> _playSong(SongModel song) async {
    // 立即进入播放页（不等网络请求），播放在后台异步进行。
    // 这样点击歌名/歌手区域一定会跳转播放页，不会再出现「已播放但停在搜索页」。
    openPlayerPage(context);

    if (song.coverUrl != null && song.coverUrl!.isNotEmpty) {
      AudioPlayerService.preFetchCover(song.coverUrl!);
    }
    // play() 内部会在封面缺失时自动补取歌曲详情，无需在此重复请求
    // 记录搜索来源（S3 弱标签）：搜索词 → 播放关联，供本地曲风推断
    final keyword = _searchController.text.trim();
    PlayContextService().setSource(
      kind: PlaySourceKind.search,
      keyword: keyword.isEmpty ? null : keyword,
    );
    final success = await _audioPlayer.playAndAdd(song);
    if (!mounted || success) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('播放失败，请检查网络或登录状态'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _playAll() async {
    if (_searchResults.isEmpty) return;
    openPlayerPage(context);
    PlayContextService().setSource(
      kind: PlaySourceKind.search,
      keyword: _submittedQuery.isEmpty ? null : _submittedQuery,
    );
    await _audioPlayer.playSongs(List<SongModel>.from(_searchResults));
  }

  @override
  void dispose() {
    _suggestDebounce?.cancel();
    _searchController.removeListener(_onSearchTextChanged);
    _searchController.dispose();
    _sourceSub?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        bottom: false,
        child: ResponsiveContent(
          child: Column(
            children: [
              _buildSearchBar(),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────── 顶栏 ───────────────────────────
  //
  // 搜索框固定在顶部：`build()` 里它是 Column 的第一个子节点，只有下方的
  // 结果区在滚动，所以滚列表时输入框不会跟着走。

  Widget _buildSearchBar() {
    final hasText = _searchController.text.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.xs,
        AppSpace.sm,
        AppSpace.page,
        AppSpace.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.row),
                border: Border.all(color: AppColors.hairline, width: 0.7),
              ),
              child: Row(
                children: [
                  const SizedBox(width: AppSpace.md),
                  const Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: AppColors.inkTertiary,
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _focusNode,
                      // 进页即获焦 → 键盘立刻弹出，不用先点输入框
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _performSearch(),
                      cursorColor: AppColors.brand,
                      style: AppType.body,
                      decoration: InputDecoration(
                        filled: false,
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        hintText: '搜索歌曲、歌手',
                        hintStyle: AppType.body.copyWith(
                          color: AppColors.inkTertiary,
                        ),
                      ),
                    ),
                  ),
                  if (hasText)
                    AppIconButton(
                      icon: Icons.cancel_rounded,
                      size: 36,
                      iconSize: 16,
                      foreground: AppColors.inkTertiary,
                      onTap: () => _searchController.clear(),
                    )
                  else
                    const SizedBox(width: AppSpace.md),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          _buildSourceBadge(),
          const SizedBox(width: AppSpace.xs),
          _buildCancelButton(),
        ],
      ),
    );
  }

  /// 「取消」：与输入框同一行、高 44，点一下退出搜索页。
  ///
  /// 有了它，左上角的返回箭头就是同一个功能的第二个按钮，直接去掉。
  Widget _buildCancelButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.maybePop(context),
        borderRadius: BorderRadius.circular(AppRadius.row),
        child: SizedBox(
          height: 44,
          child: Center(
            widthFactor: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
              child: Text(
                '取消',
                style: AppType.body.copyWith(
                  color: AppColors.brand,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 顶栏音源标识（REQ-07）：说明这次搜索打的是哪个源
  Widget _buildSourceBadge() {
    return StreamBuilder<SongSource>(
      stream: SourceManager().onSourceChanged,
      initialData: SourceManager().currentSource,
      builder: (context, snapshot) {
        final kind = snapshot.data ?? SongSource.netease;
        return AppTag(
          text: kind.label,
          color: AppColors.brand,
          background: AppColors.brandSoft,
        );
      },
    );
  }

  // ─────────────────────────── 状态分发 ───────────────────────────

  Widget _buildBody() {
    if (_isLoading) return _buildSkeletonList();

    if (_searchResults.isNotEmpty || _errorMessage.isNotEmpty) {
      return _buildSearchResults();
    }

    if (_suggestions.isNotEmpty) return _buildSuggestions();

    return _buildInitialContent();
  }

  /// 加载态用骨架行而不是居中转圈：形状预示结果，等待感更短。
  Widget _buildSkeletonList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.page,
        vertical: AppSpace.xs,
      ),
      itemCount: 8,
      itemBuilder: (context, index) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            AppSkeleton(width: 48, height: 48, radius: 12),
            SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppSkeleton(width: 168, height: 13, radius: 6),
                  SizedBox(height: AppSpace.sm),
                  AppSkeleton(width: 96, height: 11, radius: 6),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────── 初始态 ───────────────────────────

  Widget _buildInitialContent() {
    if (_hotKeys.isEmpty && _searchHistory.isEmpty) {
      return const AppEmptyState(
        icon: Icons.search_rounded,
        title: '输入关键词开始搜索',
        message: '歌名、歌手都能搜，也可以直接从热搜里挑一个',
      );
    }

    return ListView(
      padding: const EdgeInsets.only(
        left: AppSpace.page,
        right: AppSpace.page,
        bottom: AppSpace.xxxl,
      ),
      children: [
        if (_searchHistory.isNotEmpty) ...[
          AppSectionHeader(
            title: '搜索历史',
            actionLabel: '清空',
            onAction: _confirmClearHistory,
            padding: const EdgeInsets.only(bottom: AppSpace.md),
          ),
          _buildHistoryChips(),
          const SizedBox(height: AppSpace.xxl),
        ],
        _buildHotSection(),
      ],
    );
  }

  Widget _buildHistoryChips() {
    return Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      children: _searchHistory.map((keyword) {
        return Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: InkWell(
            onTap: () => _submitKeyword(keyword),
            onLongPress: () async {
              // 长按删单条：手势不该是唯一入口，所以保留「清空」显式按钮
              await _historyService.remove(keyword);
              if (mounted) {
                setState(() {
                  _searchHistory = _historyService.history;
                });
              }
            },
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(color: AppColors.hairline, width: 0.7),
              ),
              alignment: Alignment.center,
              child: Text(
                keyword,
                style: AppType.caption.copyWith(color: AppColors.ink),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildHotSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppSectionHeader(
          title: '热搜榜',
          subtitle: '长按历史可删除单条',
          padding: EdgeInsets.zero,
        ),
        const SizedBox(height: AppSpace.md),
        if (_hotKeys.isEmpty)
          const AppEmptyState(
            icon: Icons.local_fire_department_outlined,
            title: '暂时取不到热搜',
            message: '直接搜歌名同样可以',
            compact: true,
          )
        else
          for (var i = 0; i < _hotKeys.length; i++)
            _buildHotRow(i, _hotKeys[i]),
      ],
    );
  }

  Widget _buildHotRow(int index, String keyword) {
    final top = index < 3;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _submitKeyword(keyword),
        borderRadius: BorderRadius.circular(AppRadius.row),
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: Text(
                  '${index + 1}',
                  textAlign: TextAlign.center,
                  style: AppType.captionStrong.copyWith(
                    fontSize: 15,
                    color: top ? AppColors.rose : AppColors.inkTertiary,
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Text(
                  keyword,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body,
                ),
              ),
              if (top)
                const AppTag(
                  text: '热',
                  color: AppColors.rose,
                  background: AppColors.roseSoft,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmClearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空搜索历史'),
        content: const Text('确定要清空所有搜索历史吗？清空后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _historyService.clear();
      if (mounted) {
        setState(() {
          _searchHistory = _historyService.history;
        });
      }
    }
  }

  // ─────────────────────────── 联想态 ───────────────────────────

  Widget _buildSuggestions() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
      itemCount: _suggestions.length,
      itemBuilder: (context, index) {
        final keyword = _suggestions[index];
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _submitKeyword(keyword),
            borderRadius: BorderRadius.circular(AppRadius.row),
            child: SizedBox(
              height: 52,
              child: Row(
                children: [
                  const SizedBox(width: AppSpace.md),
                  const Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: AppColors.inkTertiary,
                  ),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: Text(
                      keyword,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.body.copyWith(fontWeight: FontWeight.w400),
                    ),
                  ),
                  const Icon(
                    Icons.north_west_rounded,
                    size: 16,
                    color: AppColors.inkDisabled,
                  ),
                  const SizedBox(width: AppSpace.md),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ─────────────────────────── 结果态 ───────────────────────────

  Widget _buildSearchResults() {
    if (_errorMessage.isNotEmpty) {
      final notFound = _errorMessage == '未找到相关歌曲';
      return AppEmptyState(
        icon: notFound ? Icons.search_off_rounded : Icons.cloud_off_rounded,
        title: notFound ? '没有找到「$_submittedQuery」' : '搜索没成功',
        message: notFound ? '换个关键词，或在设置里切换音源再试' : _errorMessage,
        actionLabel: '重新搜索',
        onAction: _performSearch,
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(
        left: AppSpace.page,
        right: AppSpace.page,
        bottom: AppSpace.xxxl,
      ),
      itemCount: _searchResults.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _buildResultHeader();
        return _buildSongRow(_searchResults[index - 1]);
      },
    );
  }

  Widget _buildResultHeader() {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${_searchResults.length} 首结果',
              style: AppType.caption.copyWith(color: AppColors.inkTertiary),
            ),
          ),
          Material(
            color: AppColors.brandSoft,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: InkWell(
              onTap: _playAll,
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.play_arrow_rounded,
                      size: 16,
                      color: AppColors.brand,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '播放全部',
                      style: AppType.captionStrong.copyWith(
                        color: AppColors.brand,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSongRow(SongModel song) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _playSong(song),
        borderRadius: BorderRadius.circular(AppRadius.row),
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: song.coverUrl != null && song.coverUrl!.isNotEmpty
                      ? _SongCoverImage(url: song.coverUrl!)
                      : const ColoredBox(
                          color: AppColors.surfaceMuted,
                          child: Icon(
                            Icons.music_note_rounded,
                            color: AppColors.inkTertiary,
                            size: 20,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _HighlightedText(
                      text: song.name,
                      keyword: _submittedQuery,
                      base: AppType.body,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.caption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              const Icon(
                Icons.more_horiz_rounded,
                size: 20,
                color: AppColors.inkDisabled,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 命中关键词高亮：把搜索词标成品牌色，长列表里更容易扫读。
class _HighlightedText extends StatelessWidget {
  const _HighlightedText({
    required this.text,
    required this.keyword,
    required this.base,
  });

  final String text;
  final String keyword;
  final TextStyle base;

  @override
  Widget build(BuildContext context) {
    final key = keyword.trim();
    if (key.isEmpty) {
      return Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }
    final lowerText = text.toLowerCase();
    final lowerKey = key.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final at = lowerText.indexOf(lowerKey, start);
      if (at < 0) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (at > start) {
        spans.add(TextSpan(text: text.substring(start, at)));
      }
      spans.add(
        TextSpan(
          text: text.substring(at, at + key.length),
          style: const TextStyle(color: AppColors.brand),
        ),
      );
      start = at + key.length;
    }
    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _SongCoverImage extends StatefulWidget {
  final String url;
  const _SongCoverImage({required this.url});

  @override
  State<_SongCoverImage> createState() => _SongCoverImageState();
}

class _SongCoverImageState extends State<_SongCoverImage>
    with SingleTickerProviderStateMixin {
  Uint8List? _imageBytes;
  bool _loading = true;

  /// 封面加载中的扫光动画（高光条循环扫过）
  late final AnimationController _shimmerController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  Future<void> _loadImage() async {
    try {
      final response = await _dio.get(
        '${widget.url.split('?').first}?param=300y300',
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Referer': 'https://music.163.com',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
        ),
      );
      if (response.statusCode == 200 && response.data != null) {
        if (mounted) {
          setState(() {
            _imageBytes = response.data as Uint8List;
            _loading = false;
          });
        }
      } else {
        if (mounted) setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    } finally {
      if (mounted) _shimmerController.stop();
    }
  }

  Widget _buildShimmer() {
    return AnimatedBuilder(
      animation: _shimmerController,
      builder: (context, _) {
        return Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xFFEDEDE9)),
            Positioned(
              left: -52 + 104 * _shimmerController.value,
              top: 0,
              bottom: 0,
              width: 52,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Color(0x00EDEDE9),
                      Color(0x99FFFFFF),
                      Color(0x00EDEDE9),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return _buildShimmer();
    if (_imageBytes != null) {
      return Image.memory(_imageBytes!, fit: BoxFit.cover);
    }
    return const ColoredBox(
      color: AppColors.surfaceMuted,
      child: Icon(
        Icons.music_note_rounded,
        color: AppColors.inkTertiary,
        size: 20,
      ),
    );
  }
}
