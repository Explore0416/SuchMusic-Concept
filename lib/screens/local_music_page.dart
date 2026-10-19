import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/song_model.dart';
import '../services/audio_player_service.dart';
import '../services/kgm_decoder.dart';
import '../services/local_music_service.dart';
import '../utils/responsive.dart';
import '../widgets/design_dialog.dart';

/// 本地音乐页。
///
/// 列出设备上的全部本地音频（系统音频库 + 目录中的 `.kgm/.kgma/.vpr` 加密文件），
/// 支持离线播放；KGM 首次播放时在本机解密并缓存，之后直接复用，全程不联网。
///
/// 视觉与「设置」「我的」页保持一致：浅灰底 `#F1F2F4`、白色导航栏、白色圆角卡片，
/// 避免在原有界面里显得突兀。
class LocalMusicPage extends StatefulWidget {
  const LocalMusicPage({super.key});

  @override
  State<LocalMusicPage> createState() => _LocalMusicPageState();
}

class _LocalMusicPageState extends State<LocalMusicPage> {
  LocalScanResult _result = LocalScanResult.empty;
  bool _loading = true;

  /// 正在解码的曲目 id（KGM 首次播放）。
  String? _decodingId;
  double _decodeProgress = 0;

  /// 「播放全部」时的批量解码进度（null 表示未在进行）。
  String? _batchText;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _loading = true;
    });
    final r = await LocalMusicService.instance.scan();
    if (!mounted) return;
    setState(() {
      _result = r;
      _loading = false;
    });
  }

  // ── 播放 ──────────────────────────────────────────────────────

  /// 确保曲目可播放：KGM 先解密到缓存，普通音频直接用原 Uri。
  Future<String?> _prepare(
    LocalTrack track, {
    bool batch = false,
    bool forceDecode = false,
  }) async {
    var isKgm = track.isKgm || forceDecode;
    // 加密格式一律走「多候选头长试解」：KGM / KGMA / VPR / KGG 的头部布局不完全一致，
    // 单一头长对不上就整首解不出。试解结果必须通过音频魔数校验，多试不会误伤。
    var forceAttempt = isKgm;
    final path = track.path;

    // 按文件头兜底识别：扩展名被改过（如 .kgm 被改名成 .flac），
    // 或属于 KGMA 等魔数不同的变体时，仅看后缀会把密文直接交给播放器
    // → just_audio 报 "(0) Source error"。
    if (!isKgm && path != null) {
      try {
        final f = File(path);
        final len = await f.length();
        final raf = await f.open();
        final head = await raf.read(64);
        await raf.close();
        final bytes = Uint8List.fromList(head);
        if (KgmDecoder.looksLikeKgm(bytes)) {
          isKgm = true;
          forceAttempt = true;
        } else if (!KgmDecoder.looksLikeAudio(bytes) &&
            KgmDecoder.canAttemptDecode(bytes, len)) {
          // 魔数不认识但头部布局像加密文件 → 试解，解错会被音频魔数校验拦下
          isKgm = true;
          forceAttempt = true;
        }
      } on FileSystemException catch (e) {
        // 权限不足 / 文件被删：直接告诉用户，而不是把坏路径丢给播放器
        final code = e.osError?.errorCode;
        if (code == 13) {
          _toast('无法读取该文件：请在系统设置中授予「所有文件访问」权限');
          return null;
        }
        if (code == 2) {
          _toast('文件已不存在（可能已被移动或清理），请重新扫描');
          return null;
        }
      } catch (_) {
        // 其它读取异常按原扩展名处理
      }
    }

    if (!isKgm) return track.uri;
    if (path == null) {
      _toast('无法读取该文件路径，请重新扫描');
      return null;
    }
    // 先看缓存是否已存在（解码器内部命中即秒回）
    try {
      final decoded = await KgmDecoder.instance.decodeToCache(
        path,
        forceAttempt: forceAttempt,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _decodeProgress = p;
            if (batch) {
              _batchText = '正在解码 ${track.name} · ${(p * 100).round()}%';
            }
          });
        },
      );
      return decoded.uri.toString();
    } on KgmDecodeException catch (e) {
      _toast('解码失败：${e.message}');
      return null;
    } catch (e) {
      _toast('解码失败：$e');
      return null;
    }
  }

  Future<void> _playAt(int index) async {
    if (_decodingId != null) return; // 上一次解码未结束，避免并发写同一缓存
    final track = _result.tracks[index];
    // 统一走 _prepare：它会按文件头兜底识别被改名的加密文件。
    // 只有标记为 KGM 的条目才展示解码进度浮层。
    if (track.isKgm) {
      setState(() {
        _decodingId = track.id;
        _decodeProgress = 0;
      });
    }
    final uri = await _prepare(track);
    if (!mounted) return;
    if (track.isKgm) setState(() => _decodingId = null);
    if (uri == null) return;
    final svc = AudioPlayerService();
    try {
      await svc.playSongs([track.toSongModel(playUri: uri)]);
    } catch (e) {
      _toast('播放失败：$e');
      return;
    }
    if (svc.state == PlayerState.error && !track.isKgm && track.path != null) {
      // 兜底：文件被改成普通后缀（如 `xxx.kgg.flac`）时，扫描层可能漏判。
      // 播放器已经证明解不开，那就按加密文件再试一次，成功则无缝续播。
      if (mounted) {
        setState(() {
          _decodingId = track.id;
          _decodeProgress = 0;
        });
      }
      final retryUri = await _prepare(track, forceDecode: true);
      if (!mounted) return;
      setState(() => _decodingId = null);
      if (retryUri != null) {
        try {
          await svc.playSongs([track.toSongModel(playUri: retryUri)]);
        } catch (_) {}
      }
      if (svc.state == PlayerState.error) {
        _toast('播放失败：${svc.lastError ?? '未知原因'}');
      }
      return;
    }
    if (!mounted) return;
    if (svc.state == PlayerState.error) {
      _toast('播放失败：${svc.lastError ?? '未知原因'}');
    }
  }

  /// 播放全部：先解码所有 KGM（带进度浮层），再一次性入队。
  Future<void> _playAll() async {
    if (_result.tracks.isEmpty || _batchText != null) return;
    final tracks = _result.tracks;
    final kgmTotal = _result.kgmCount;
    if (kgmTotal > 0) {
      setState(() => _batchText = '准备中…');
    }
    final songs = <String, String>{}; // index → playUri
    try {
      for (var i = 0; i < tracks.length; i++) {
        final t = tracks[i];
        if (_batchText != null) {
          setState(() => _batchText = '正在准备 ${t.name}（${songs.length + 1}/${tracks.length}）');
        }
        final uri = await _prepare(t, batch: true);
        if (uri == null) continue;
        songs['$i'] = uri;
      }
    } finally {
      if (mounted) setState(() => _batchText = null);
    }
    if (!mounted) return;
    final models = <SongModel>[];
    for (var i = 0; i < tracks.length; i++) {
      final uri = songs['$i'];
      if (uri == null) continue;
      models.add(tracks[i].toSongModel(playUri: uri));
    }
    if (models.isEmpty) {
      _toast('没有可播放的本地音乐');
      return;
    }
    final svc = AudioPlayerService();
    await svc.playSongs(models);
    if (!mounted) return;
    if (svc.state == PlayerState.error) {
      _toast('播放失败：${svc.lastError ?? '未知原因'}');
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    DesignToast.show(context, text);
  }

  // ── 权限 ──────────────────────────────────────────────────────

  Future<void> _openAllFilesSettings() async {
    final ok = await LocalMusicService.instance.openAllFilesSettings();
    if (!ok) {
      _toast('无法打开系统设置，请手动授予「所有文件访问」权限');
      return;
    }
    _toast('授权后返回本页，点右上角刷新即可扫描 KGM');
  }

  // ── UI ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final s = Responsive.uiScale(size);
    final topPadding = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: const Color(0xFFF1F2F4),
      body: Column(
        children: [
          _buildNavBar(s, topPadding),
          Expanded(
            child: _loading
                ? const Center(
                    child: SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Color(0xFF2F84FE),
                      ),
                    ),
                  )
                : ResponsiveContent(
                    child: ListView(
                      padding: EdgeInsets.only(
                        top: 12 * s,
                        bottom: 28 * s,
                        left: 16 * s,
                        right: 16 * s,
                      ),
                      children: [
                        _buildSummary(s),
                        if (!_result.allFilesAccess) ...[
                          SizedBox(height: 10 * s),
                          _buildKgmPermissionCard(s),
                        ],
                        SizedBox(height: 12 * s),
                        if (_result.tracks.isEmpty)
                          _buildEmpty(s)
                        else
                          ..._buildRows(s),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavBar(double s, double topPadding) {
    return Container(
      padding: EdgeInsets.only(top: topPadding),
      color: Colors.white,
      child: SizedBox(
        height: 44 * s,
        child: Stack(
          children: [
            Positioned(
              left: 12 * s,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onTap: () => Navigator.pop(context),
                behavior: HitTestBehavior.opaque,
                child: Row(
                  children: [
                    const Icon(Icons.arrow_back_ios_new,
                        size: 20, color: Colors.black),
                    SizedBox(width: 8 * s - 3),
                    Text('返回',
                        style: TextStyle(color: Colors.black, fontSize: 14 * s)),
                  ],
                ),
              ),
            ),
            Center(
              child: Text(
                '本地音乐',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 17.5 * s,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Positioned(
              right: 14 * s,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onTap: _loading ? null : () {
                  HapticFeedback.selectionClick();
                  _scan();
                },
                behavior: HitTestBehavior.opaque,
                child: Icon(Icons.refresh_rounded,
                    size: 22 * s, color: const Color(0xFF333333)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummary(double s) {
    final total = _result.tracks.length;
    final kgm = _result.kgmCount;
    final text = total == 0
        ? '未找到本地音乐'
        : kgm > 0
            ? '共 $total 首 · 其中加密格式 $kgm 首'
            : '共 $total 首';
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 13 * s, color: const Color(0xFF838383)),
          ),
        ),
        if (total > 0)
          GestureDetector(
            onTap: _playAll,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 14 * s, vertical: 6 * s),
              decoration: BoxDecoration(
                color: const Color(0xFF2F84FE),
                borderRadius: BorderRadius.circular(16 * s),
              ),
              child: Row(
                children: [
                  Icon(Icons.play_arrow_rounded,
                      size: 17 * s, color: Colors.white),
                  SizedBox(width: 2 * s),
                  Text('播放全部',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12.5 * s,
                        fontWeight: FontWeight.w500,
                      )),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildKgmPermissionCard(double s) {
    return Container(
      padding: EdgeInsets.all(14 * s),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10 * s),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock_outline_rounded,
                  size: 17 * s, color: const Color(0xFF2F84FE)),
              SizedBox(width: 6 * s),
              Text('解锁 .kgm 等加密格式',
                  style: TextStyle(
                    fontSize: 14 * s,
                    color: const Color(0xFF333333),
                    fontWeight: FontWeight.w500,
                  )),
            ],
          ),
          SizedBox(height: 6 * s),
          Text(
            '系统音频库不索引酷狗加密文件。授予「所有文件访问」权限后重新扫描，'
            '即可列出并在本机离线解码播放（不联网、不上传）。',
            style: TextStyle(
              fontSize: 12 * s,
              height: 1.45,
              color: const Color(0xFF838383),
            ),
          ),
          SizedBox(height: 10 * s),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: _openAllFilesSettings,
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding:
                    EdgeInsets.symmetric(horizontal: 14 * s, vertical: 7 * s),
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF2FF),
                  borderRadius: BorderRadius.circular(15 * s),
                ),
                child: Text('去授权',
                    style: TextStyle(
                      color: const Color(0xFF2F84FE),
                      fontSize: 12.5 * s,
                      fontWeight: FontWeight.w500,
                    )),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(double s) {
    return Padding(
      padding: EdgeInsets.only(top: 60 * s),
      child: Column(
        children: [
          Icon(Icons.music_note_outlined,
              size: 46 * s, color: const Color(0xFFCCCCCC)),
          SizedBox(height: 12 * s),
          Text(
            _result.audioPermission ? '设备上暂无可播放的音频' : '需要「音乐和音频」权限才能扫描',
            style: TextStyle(fontSize: 14 * s, color: const Color(0xFF838383)),
          ),
          SizedBox(height: 6 * s),
          Text(
            '点右上角刷新可重新申请权限',
            style: TextStyle(fontSize: 12 * s, color: const Color(0xFFAAAAAA)),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildRows(double s) {
    final rows = <Widget>[];
    for (var i = 0; i < _result.tracks.length; i++) {
      final t = _result.tracks[i];
      rows.add(Padding(
        padding: EdgeInsets.only(bottom: 8 * s),
        child: _buildRow(s, i, t),
      ));
    }
    return rows;
  }

  Widget _buildRow(double s, int index, LocalTrack t) {
    final decodingThis = _decodingId == t.id;
    return GestureDetector(
      onTap: () => _playAt(index),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 10 * s),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10 * s),
        ),
        child: Row(
          children: [
            // 序号 / 播放态
            SizedBox(
              width: 26 * s,
              child: decodingThis
                  ? SizedBox(
                      width: 15 * s,
                      height: 15 * s,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: _decodeProgress > 0 ? _decodeProgress : null,
                        color: const Color(0xFF2F84FE),
                      ),
                    )
                  : Text(
                      '${index + 1}',
                      style: TextStyle(
                          fontSize: 13 * s, color: const Color(0xFFBBBBBB)),
                    ),
            ),
            // 封面占位（与首页/歌单一致的薄荷色块 + 音符）
            Container(
              width: 40 * s,
              height: 40 * s,
              decoration: BoxDecoration(
                color: const Color(0xFFEAF2FF),
                borderRadius: BorderRadius.circular(8 * s),
              ),
              child: Icon(Icons.music_note_rounded,
                  size: 21 * s, color: const Color(0xFF2F84FE)),
            ),
            SizedBox(width: 10 * s),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5 * s,
                      color: const Color(0xFF333333),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  SizedBox(height: 3 * s),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          t.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5 * s,
                              color: const Color(0xFF838383)),
                        ),
                      ),
                      SizedBox(width: 6 * s),
                      _buildFormatChip(s, t),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(width: 8 * s),
            Text(
              t.durationLabel,
              style: TextStyle(fontSize: 11.5 * s, color: const Color(0xFFAAAAAA)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFormatChip(double s, LocalTrack t) {
    final isKgm = t.isKgm;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 5 * s, vertical: 1 * s),
      decoration: BoxDecoration(
        color: isKgm ? const Color(0xFFFFF3E6) : const Color(0xFFF2F3F5),
        borderRadius: BorderRadius.circular(4 * s),
      ),
      child: Text(
        t.formatLabel,
        style: TextStyle(
          fontSize: 9.5 * s,
          height: 1.2,
          fontWeight: FontWeight.w500,
          color: isKgm ? const Color(0xFFE08A2E) : const Color(0xFF9A9A9A),
        ),
      ),
    );
  }
}
