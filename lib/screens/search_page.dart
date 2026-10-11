import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../models/song_model.dart';
import '../services/music_api_service.dart';
import '../services/audio_player_service.dart';
import '../services/search_history_service.dart';
import '../services/sources/source_manager.dart';
import '../services/app_init.dart';
import '../utils/responsive.dart';
import 'player_page.dart';

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

  double _backScale = 1.0;
  double _searchScale = 1.0;
  bool _isLoading = false;
  List<SongModel> _searchResults = [];
  List<String> _hotKeys = [];
  List<String> _suggestions = [];
  List<String> _searchHistory = [];
  String _errorMessage = '';

  StreamSubscription<SongSource>? _sourceSub;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadHotKeys();
    _searchController.addListener(_onSearchTextChanged);
    // 音源切换后刷新热搜并清空旧结果
    _sourceSub = SourceManager().onSourceChanged.listen((_) {
      if (!mounted) return;
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
    _loadSuggestions(query);
  }

  Future<void> _loadSuggestions(String query) async {
    // 搜索联想为网易云专属；其它音源下不提供
    if (SourceManager().currentSource != SongSource.netease) {
      if (mounted) setState(() => _suggestions = []);
      return;
    }
    final suggestions = await _apiService.searchSuggest(query);
    if (mounted && _searchController.text.trim() == query) {
      setState(() {
        _suggestions = suggestions;
      });
    }
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
          _errorMessage = '搜索失败: ${e.toString().replaceFirst('Exception: ', '')}';
        });
      }
    }
  }

  Future<void> _playSong(SongModel song) async {
    SongModel playSong = song;
    final detail = await SourceManager().source.getSongDetail(song);
    if (detail != null) {
      playSong = detail;
    }

    final success = await _audioPlayer.playAndAdd(playSong);
    if (playSong.coverUrl != null) {
      AudioPlayerService.preFetchCover(playSong.coverUrl!);
    }
    if (!mounted) return;

    if (success) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const PlayerPage()),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('播放失败，请检查网络或登录状态'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchTextChanged);
    _searchController.dispose();
    _sourceSub?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F2F4),
      body: SafeArea(
        child: ResponsiveContent(
          child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
              child: Column(
                children: [
                  _buildSearchBar(),
                  const SizedBox(height: 16),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 15),
                child: _buildBody(),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF09244B)),
      );
    }

    if (_searchResults.isNotEmpty || _errorMessage.isNotEmpty) {
      return _buildSearchResults();
    }

    if (_suggestions.isNotEmpty) {
      return _buildSuggestions();
    }

    return _buildInitialContent();
  }

  Widget _buildSearchBar() {
    return Row(
      children: [
        GestureDetector(
          onTapDown: (_) {
            setState(() {
              _backScale = 0.85;
            });
          },
          onTapUp: (_) {
            setState(() {
              _backScale = 1.15;
            });
            Future.delayed(const Duration(milliseconds: 120), () {
              if (mounted) {
                setState(() {
                  _backScale = 1.0;
                });
              }
            });
            Navigator.pop(context);
          },
          onTapCancel: () {
            setState(() {
              _backScale = 1.0;
            });
          },
          child: AnimatedScale(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            scale: _backScale,
            child: Container(
              margin: const EdgeInsets.only(right: 12),
              width: 24,
              height: 24,
              child: SvgPicture.string(
                '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 1024 1024"><path d="M747.245 81.064c-28.497-29.315-74.739-29.315-103.307 0l-367.236 378.011c-28.483 29.367-28.483 76.982 0 106.291l367.236 377.997c28.562 29.367 74.806 29.367 103.307 0 28.546-29.325 28.546-76.929 0-106.304l-315.6-324.841 315.599-324.803c28.545-29.367 28.544-76.973 0-106.356l0 0z" fill="#CACACA"></path></svg>',
              ),
            ),
          ),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(30),
            ),
            child: TextField(
              controller: _searchController,
              focusNode: _focusNode,
              autofocus: true,
              onSubmitted: (_) => _performSearch(),
              decoration: const InputDecoration(
                hintText: '搜索歌曲',
                hintStyle: TextStyle(
                  color: Colors.black,
                  fontSize: 14,
                ),
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              ),
            ),
          ),
        ),
        GestureDetector(
          onTapDown: (_) {
            setState(() {
              _searchScale = 0.85;
            });
          },
          onTapUp: (_) {
            setState(() {
              _searchScale = 1.15;
            });
            Future.delayed(const Duration(milliseconds: 120), () {
              if (mounted) {
                setState(() {
                  _searchScale = 1.0;
                });
              }
            });
          },
          onTapCancel: () {
            setState(() {
              _searchScale = 1.0;
            });
          },
          onTap: _performSearch,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            scale: _searchScale,
            child: Container(
              margin: const EdgeInsets.only(left: 12),
              child: const Text(
                '搜索',
                style: TextStyle(
                  color: Color(0xFF7C7C7C),
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _buildSourceBadge(),
      ],
    );
  }

  /// 顶栏音源标识（REQ-07）
  Widget _buildSourceBadge() {
    return StreamBuilder<SongSource>(
      stream: SourceManager().onSourceChanged,
      initialData: SourceManager().currentSource,
      builder: (context, snapshot) {
        final kind = snapshot.data ?? SongSource.netease;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFFE8F0FF),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            kind.label,
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF2F84FE),
              fontWeight: FontWeight.w500,
            ),
          ),
        );
      },
    );
  }

  Widget _buildSuggestions() {
    return ListView.separated(
      itemCount: _suggestions.length,
      separatorBuilder: (context, i) => const Divider(height: 1, color: Color(0xFFEEEEEE)),
      itemBuilder: (context, index) {
        final keyword = _suggestions[index];
        return ListTile(
          leading: const Icon(Icons.search, color: Color(0xFFB0B0B0)),
          title: Text(
            keyword,
            style: const TextStyle(fontSize: 14, color: Colors.black87),
          ),
          onTap: () {
            _searchController.text = keyword;
            _searchController.selection = TextSelection.fromPosition(
              TextPosition(offset: keyword.length),
            );
            _performSearch();
          },
        );
      },
    );
  }

  Widget _buildInitialContent() {
    if (_hotKeys.isEmpty && _searchHistory.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search, size: 48, color: Colors.grey[300]),
            const SizedBox(height: 12),
            Text(
              '输入关键词搜索歌曲',
              style: TextStyle(color: Colors.grey[400], fontSize: 14),
            ),
          ],
        ),
      );
    }

    final children = <Widget>[];

    if (_searchHistory.isNotEmpty) {
      children.add(_buildHistorySection());
      children.add(const SizedBox(height: 20));
    }

    children.add(const Padding(
      padding: EdgeInsets.only(left: 4, bottom: 12),
      child: Text(
        '热搜榜',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
      ),
    ));

    for (var i = 0; i < _hotKeys.length; i++) {
      final keyword = _hotKeys[i];
      children.add(ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: SizedBox(
          width: 24,
          child: Text(
            '${i + 1}',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: i < 3 ? const Color(0xFFE83220) : Colors.grey[500],
            ),
          ),
        ),
        title: Text(
          keyword,
          style: const TextStyle(fontSize: 14, color: Colors.black87),
        ),
        trailing: const Icon(Icons.chevron_right, color: Color(0xFFCCCCCC)),
        onTap: () {
          _searchController.text = keyword;
          _searchController.selection = TextSelection.fromPosition(
            TextPosition(offset: keyword.length),
          );
          _performSearch();
        },
      ));
      if (i < _hotKeys.length - 1) {
        children.add(const Divider(height: 1, color: Color(0xFFEEEEEE)));
      }
    }

    return ListView(
      padding: EdgeInsets.zero,
      children: children,
    );
  }

  Widget _buildHistorySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '搜索历史',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              GestureDetector(
                onTap: _confirmClearHistory,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.delete_outline,
                      size: 20, color: Colors.grey[500]),
                ),
              ),
            ],
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _searchHistory.map((keyword) {
            return GestureDetector(
              onTap: () {
                _searchController.text = keyword;
                _searchController.selection = TextSelection.fromPosition(
                  TextPosition(offset: keyword.length),
                );
                _performSearch();
              },
              onLongPress: () async {
                await _historyService.remove(keyword);
                if (mounted) {
                  setState(() {
                    _searchHistory = _historyService.history;
                  });
                }
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  keyword,
                  style: const TextStyle(fontSize: 13, color: Colors.black87),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Future<void> _confirmClearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空搜索历史'),
        content: const Text('确定要清空所有搜索历史吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
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

  Widget _buildSearchResults() {
    if (_errorMessage.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.music_off, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 12),
            Text(
              _errorMessage,
              style: TextStyle(color: Colors.grey[500], fontSize: 14),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        return _buildSongItem(_searchResults[index]);
      },
    );
  }

  Widget _buildSongItem(SongModel song) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: Colors.white,
          child: ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            leading: null,
            title: Text(
              song.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: Colors.black87,
              ),
            ),
            subtitle: Text(
              song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[500],
              ),
            ),
            trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: () => _playSong(song),
                        child: SvgPicture.asset(
                          'assets/images/svg/play_circle.svg',
                          width: 24,
                          height: 24,
                          colorFilter: const ColorFilter.mode(
                            Color(0xFFB0B0B0),
                            BlendMode.srcIn,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SvgPicture.asset(
                        'assets/images/svg/Dots Horizontal.svg',
                        width: 20,
                        height: 20,
                        colorFilter: const ColorFilter.mode(
                          Color(0xFFB0B0B0),
                          BlendMode.srcIn,
                        ),
                      ),
                    ],
                  ),
            onTap: () => _playSong(song),
          ),
        ),
      ),
    );
  }
}
