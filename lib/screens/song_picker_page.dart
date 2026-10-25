import 'package:flutter/material.dart';

import '../models/song_model.dart';
import '../services/audio_player_service.dart';
import '../utils/responsive.dart';

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

  @override
  Widget build(BuildContext context) {
    final s = Responsive.uiScale(MediaQuery.of(context).size);
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: Text(widget.title,
            style: TextStyle(fontSize: 17 * s, fontWeight: FontWeight.w600)),
        actions: [
          TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () => Navigator.pop(
                      context,
                      _songs.where((x) => _selected.contains(x.id)).toList(),
                    ),
            child: Text(
              _selected.isEmpty ? '确定' : '确定(${_selected.length})',
              style: TextStyle(
                fontSize: 15 * s,
                color: _selected.isEmpty
                    ? const Color(0xFFB9D0F5)
                    : const Color(0xFF2F84FE),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      body: _songs.isEmpty
          ? Center(
              child: Text(
                '当前播放列表是空的\n先播放一些歌曲再来添加',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13 * s, color: const Color(0xFF999999)),
              ),
            )
          : ListView.separated(
              padding: EdgeInsets.symmetric(vertical: 8 * s),
              itemCount: _songs.length,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                indent: 56 * s,
                color: const Color(0xFFF0F0F0),
              ),
              itemBuilder: (_, i) {
                final song = _songs[i];
                final checked = _selected.contains(song.id);
                return ListTile(
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16 * s, vertical: 2 * s),
                  leading: Icon(
                    checked
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: checked
                        ? const Color(0xFF2F84FE)
                        : const Color(0xFFCCCCCC),
                    size: 22 * s,
                  ),
                  title: Text(
                    song.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15 * s, color: Colors.black87),
                  ),
                  subtitle: Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12 * s, color: const Color(0xFF999999)),
                  ),
                  onTap: () => setState(() {
                    if (!_selected.remove(song.id)) _selected.add(song.id);
                  }),
                );
              },
            ),
    );
  }
}
