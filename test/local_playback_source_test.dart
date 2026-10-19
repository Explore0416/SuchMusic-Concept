import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/services/audio_player_service.dart';

/// 回归：本地曲目必须使用 localUri 播放。
///
/// 历史缺陷：`playSongs()` 只向在线音源取地址，本地曲目拿不到地址 →
/// 队列为空 → 状态 error，界面表现就是时长 00:00、按播放无反应。
void main() {
  SongModel local(String? uri, {String ext = 'flac'}) => SongModel(
        id: 'local:$uri',
        name: '东风破',
        artist: '周杰伦',
        album: '',
        source: SongSource.local,
        localUri: uri,
      );

  test('file:// 本地曲目返回对应 Uri', () {
    final uri = localSourceUriOf(local('file:///data/user/0/x/cache/a.flac'));
    expect(uri, isNotNull);
    expect(uri!.scheme, 'file');
    expect(uri.toFilePath(), '/data/user/0/x/cache/a.flac');
  });

  test('content:// 本地曲目同样返回 Uri', () {
    final uri = localSourceUriOf(local('content://media/external/audio/1'));
    expect(uri, isNotNull);
    expect(uri!.scheme, 'content');
  });

  test('无 localUri 的在线曲目返回 null（交由音源解析）', () {
    expect(localSourceUriOf(local(null)), isNull);
    expect(localSourceUriOf(local('')), isNull);
  });

  group('播放列表持久化', () {
    test('toJson/fromStorage 往返保留 localUri', () {
      final src = local('file:///data/user/0/x/cache/a.flac');
      final restored = SongModel.fromStorage(
        Map<String, dynamic>.from(src.toJson()),
      );
      expect(restored.localUri, 'file:///data/user/0/x/cache/a.flac');
      expect(restored.source.isLocal, isTrue);
      expect(localSourceUriOf(restored), isNotNull);
    });

    test('旧数据没有 localUri 时，从 local: 前缀的 ID 自愈', () {
      final old = <String, dynamic>{
        'id': 'local:file:///storage/emulated/0/Music/%E4%B8%9C%E9%A3%8E%E7%A0%B4.kgm',
        'name': '东风破',
        'artist': '未知歌手',
        'album': '',
        'source': 'local',
      };
      final restored = SongModel.fromStorage(old);
      expect(restored.source.isLocal, isTrue);
      expect(restored.localUri, isNotNull);
      expect(restored.localUri!.startsWith('file://'), isTrue);
      expect(localSourceUriOf(restored), isNotNull);
    });

    test('非本地 ID 不会被误解析出路径', () {
      final online = <String, dynamic>{
        'id': '1234567',
        'name': '晴天',
        'source': 'netease',
      };
      expect(SongModel.fromStorage(online).localUri, isNull);
    });
  });

  test('在线曲目的 localUri 为空，不受影响', () {
    const song = SongModel(
      id: 'n1',
      name: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      source: SongSource.netease,
    );
    expect(localSourceUriOf(song), isNull);
  });
}
