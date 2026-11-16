import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/song_model.dart';
import 'audio_player_service.dart';

/// 本地音乐「打开方式 / 分享」入站事件（Android 侧 MainActivity 转发）。
///
/// 用户在系统文件管理器里对音频文件选「打开方式 → Such Music」，或由其他 App
/// 分享音频到 Such Music 时，原生侧会把音频 Uri 与显示名经 EventChannel 送来，
/// 这里转成一条本地歌曲并立即播放。**全程只在本机处理，不上传任何数据。**
class LocalAudioIntentService {
  LocalAudioIntentService._internal();

  static final LocalAudioIntentService instance =
      LocalAudioIntentService._internal();

  /// 与 `MainActivity.INBOUND_AUDIO_CHANNEL` 保持一致。
  static const EventChannel _channel =
      EventChannel('com.lightningteam.suchmusic/inbound_audio');

  final AudioPlayerService _audioPlayer = AudioPlayerService();

  StreamSubscription<dynamic>? _sub;

  /// 开始监听（幂等；重复调用不会重复订阅）。
  void start() {
    _sub ??= _channel.receiveBroadcastStream().listen(
      _onEvent,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  /// 入站音频只接受的来源 scheme（content:// 分享/打开方式，file:// 本地路径）。
  ///
  /// `suchmusic://` 是第三方授权深链，绝不能当歌曲播放 ——
  /// 一旦漏进来，`lastPathSegment` 会让播放条出现「authorize 正在播放」。
  /// 原生侧（MainActivity.captureInboundAudio）已过滤，这里是双保险。
  @visibleForTesting
  static bool acceptsSource(String uri) {
    final scheme = Uri.tryParse(uri)?.scheme?.toLowerCase() ?? '';
    return scheme == 'content' || scheme == 'file';
  }

  /// 原生事件形如 `{ "uri": "content://...", "name": "xxx.mp3" }`。
  Future<void> _onEvent(dynamic event) async {
    if (event is! Map) return;
    final uri = event['uri']?.toString() ?? '';
    if (uri.isEmpty) return;
    if (!acceptsSource(uri)) return;
    final name = event['name']?.toString();
    final song = SongModel.fromLocalUri(uri, displayName: name);
    await _audioPlayer.playAndAdd(song);
  }
}
