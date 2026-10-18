import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'kgm_tables.dart';

/// KGM / KGMA / VPR 离线解码器（纯 Dart，无原生依赖）。
///
/// **算法来源**：开源项目 [unlock-music](https://github.com/unlock-music/unlock-music)
/// 的 `KgmWasm/kgm.hpp`（MIT 许可），逐行移植；三张 272 字节表见 `kgm_tables.dart`。
///
/// 处理流程：
/// 1. 校验 16 字节魔数（KGM 或 VPR）；
/// 2. 读 `0x10` 处的 uint32（小端）作为音频数据起始偏移；
/// 3. 取 `0x1C` 起 16 字节作为密钥，第 17 字节补 0；
/// 4. 逐字节 `key ^ data` 后再与按位置推导的 mask 异或，得到原始音频；
/// 5. 按文件头嗅探真实格式（mp3/flac/ogg/wav/m4a），写入缓存文件。
///
/// 解码结果按「源路径 + 修改时间 + 大小」做 SHA-1 缓存，重复播放不重复解密。
class KgmDecoder {
  KgmDecoder._();

  static final KgmDecoder instance = KgmDecoder._();

  /// 单次解密分块大小：每处理这么多字节让出一次事件循环，避免长时间卡 UI。
  static const int _chunkBytes = 1 << 20; // 1 MiB

  /// 是否为 KGM 家族文件（KGM / KGMA / VPR）。
  static bool looksLikeKgm(Uint8List head) {
    if (head.length < 16) return false;
    return _hasPrefix(head, kgmHeader) || _hasPrefix(head, vprHeader);
  }

  /// 是否为 VPR 变体（额外一层 `vprMaskDiff` 异或）。
  static bool _isVpr(Uint8List head) => _hasPrefix(head, vprHeader);

  static bool _hasPrefix(Uint8List bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  /// 嗅探解密后音频的真实扩展名（用于给播放器正确的容器提示）。
  static String sniffExtension(Uint8List data) {
    if (data.length < 12) return 'mp3';
    // fLaC
    if (data[0] == 0x66 && data[1] == 0x4C && data[2] == 0x61 && data[3] == 0x43) {
      return 'flac';
    }
    // OggS
    if (data[0] == 0x4F && data[1] == 0x67 && data[2] == 0x67 && data[3] == 0x53) {
      return 'ogg';
    }
    // RIFF....WAVE
    if (data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46) {
      return 'wav';
    }
    // ....ftyp
    if (data[4] == 0x66 && data[5] == 0x74 && data[6] == 0x79 && data[7] == 0x70) {
      return 'm4a';
    }
    // ID3 或 MPEG 帧同步
    if (data[0] == 0x49 && data[1] == 0x44 && data[2] == 0x33) return 'mp3';
    if (data[0] == 0xFF && (data[1] & 0xE0) == 0xE0) return 'mp3';
    return 'mp3';
  }

  /// 解析 KGM/VPR 文件头。
  ///
  /// 布局：`0x00-0x0F` 魔数，`0x10-0x13` 音频起始偏移（uint32 小端），
  /// `0x1C-0x2B` 16 字节密钥（第 17 字节补 0）。
  ///
  /// **[fileLength] 必传**（调用方只有文件大小）：`headerLen` 是相对于**整个文件**的偏移，
  /// 常见值是 1024（0x400），远大于只用于解析头部的 64 字节采样缓冲。
  /// 早期版本用 `headerLen >= bytes.length` 校验，导致所有真实 KGM 文件在第一步就抛
  /// 「头部长度字段异常」——真实文件根本解不出来。
  static KgmHeader parseHeader(Uint8List bytes, {int? fileLength}) {
    if (!looksLikeKgm(bytes)) {
      throw KgmDecodeException('不是有效的 KGM/VPR 文件（文件头不匹配）');
    }
    if (bytes.length < 0x2C) {
      throw KgmDecodeException('文件过短，头部不完整');
    }
    final headerLen = ByteData.sublistView(bytes, 0x10, 0x14)
        .getUint32(0, Endian.little);
    final limit = fileLength ?? bytes.length;
    if (headerLen < 0x2C || headerLen >= limit) {
      throw KgmDecodeException('头部长度字段异常：$headerLen（文件 $limit 字节）');
    }
    final key = Uint8List(17);
    key.setRange(0, 16, bytes, 0x1C);
    key[16] = 0;
    return KgmHeader(
      headerLen: headerLen,
      key: key,
      isVpr: _isVpr(bytes),
    );
  }

  /// 解密后的数据是否像真实音频（防止密钥/偏移不对时把乱码写成可播放文件）。
  ///
  /// 判定只认确定性魔数：ID3 / MPEG 帧同步 / fLaC / OggS / RIFF(WAVE) / ftyp。
  static bool looksLikeAudio(Uint8List head) {
    if (head.length < 12) return false;
    if (head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) return true; // ID3
    if (head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) return true; // MPEG 帧
    if (head[0] == 0x66 && head[1] == 0x4C && head[2] == 0x61 && head[3] == 0x43) {
      return true; // fLaC
    }
    if (head[0] == 0x4F && head[1] == 0x67 && head[2] == 0x67 && head[3] == 0x53) {
      return true; // OggS
    }
    if (head[0] == 0x52 && head[1] == 0x49 && head[2] == 0x46 && head[3] == 0x46 &&
        head[8] == 0x57 && head[9] == 0x41 && head[10] == 0x56 && head[11] == 0x45) {
      return true; // RIFF....WAVE
    }
    if (head[4] == 0x66 && head[5] == 0x74 && head[6] == 0x79 && head[7] == 0x70) {
      return true; // ....ftyp
    }
    return false;
  }

  /// 就地解密一段音频字节（纯函数，便于单测与复用）。
  ///
  /// [basePos] 是该段在**整段音频数据**中的起始偏移（分块解密时必须传对，
  /// 因为 key 索引与 mask 都依赖绝对位置）。
  static Uint8List transformChunk(
    Uint8List data,
    Uint8List key,
    int basePos, {
    bool isVpr = false,
  }) {
    var block = -1;
    var blockValue = 0;
    for (var i = 0; i < data.length; i++) {
      final pos = basePos + i;
      var med8 = key[pos % 17] ^ data[i];
      med8 ^= (med8 & 0x0F) << 4;
      med8 &= 0xFF;

      final b = pos >> 4;
      if (b != block) {
        block = b;
        blockValue = kgmBlockValue(b);
      }
      var msk8 = kgmMaskPreDef(pos) ^ blockValue;
      msk8 ^= (msk8 & 0x0F) << 4;
      msk8 &= 0xFF;

      var out = med8 ^ msk8;
      if (isVpr) {
        out ^= vprMaskDiff[pos % 17];
      }
      data[i] = out;
    }
    return data;
  }

  /// 把 `[srcPath]` 的 KGM 文件解密到缓存，返回可播放的文件路径。
  ///
  /// [onProgress] 传入 0..1 的进度（按字节计）。缓存命中时回调 1.0 并直接返回。
  /// 失败抛 [KgmDecodeException]（带可读原因）。
  Future<DecodedAudio> decodeToCache(
    String srcPath, {
    void Function(double progress)? onProgress,
  }) async {
    final src = File(srcPath);
    if (!await src.exists()) {
      throw KgmDecodeException('文件不存在：$srcPath');
    }
    final stat = await src.stat();
    final cacheKey = sha1.convert(
      '$srcPath|${stat.size}|${stat.modified.millisecondsSinceEpoch}'.codeUnits,
    );
    final cacheDir = Directory(
      '${(await getTemporaryDirectory()).path}/local_audio_cache',
    );
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }

    // 先读头部判断格式与后缀，命中缓存可直接返回
    final raf = await src.open();
    try {
      final head = await raf.read(64);
      final header = parseHeader(head, fileLength: stat.size);
      final headerLen = header.headerLen;
      final key = header.key;
      final isVpr = header.isVpr;

      // 缓存文件先按临时名写，嗅探出真实格式后再改成正确的音频扩展名
      // （扩展名必须是 mp3/flac/ogg/wav/m4a，播放器据此选择解复用器）
      final tmpPath = '${cacheDir.path}/$cacheKey.part';
      final prefix = '$cacheKey.';
      final existing = Directory(cacheDir.path)
          .listSync()
          .whereType<File>()
          .where((f) {
        final base = f.path.split('/').last;
        return base.startsWith(prefix) && !base.endsWith('.part');
      }).toList();
      if (existing.isNotEmpty) {
        onProgress?.call(1);
        final f = existing.first;
        final base = f.path.split('/').last;
        final ext = base.substring(prefix.length).split('.').first;
        return DecodedAudio(
          path: f.path,
          extension: ext,
          fromCache: true,
        );
      }

      await raf.setPosition(headerLen);
      final audioLength = stat.size - headerLen;

      final sniff = <int>[];
      final sink = File(tmpPath).openWrite();
      try {
        var processed = 0;
        while (processed < audioLength) {
          final want = (audioLength - processed) < _chunkBytes
              ? audioLength - processed
              : _chunkBytes;
          final chunk = await raf.read(want);
          if (chunk.isEmpty) break;
          final data = transformChunk(
            Uint8List.fromList(chunk),
            key,
            processed,
            isVpr: isVpr,
          );
          if (sniff.isEmpty && data.isNotEmpty) {
            sniff.addAll(data.take(16));
          }
          sink.add(data);
          processed += data.length;
          onProgress?.call(audioLength == 0 ? 1 : processed / audioLength);
          // 让出事件循环，界面不被长任务卡住
          await Future<void>.delayed(Duration.zero);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      // 解密结果必须是可识别音频；否则说明该文件的密钥/头部布局不是标准 KGM，
      // 直接报错，避免把乱码写成 .mp3 后播放器只显示 00:00。
      final sniffBytes = Uint8List.fromList(sniff);
      if (!looksLikeAudio(sniffBytes)) {
        try {
          await File(tmpPath).delete();
        } catch (_) {}
        throw KgmDecodeException('解密结果不是可识别的音频格式（该文件可能不是标准 KGM/KGMA）');
      }

      final extName = sniffExtension(sniffBytes);
      final finalPath = '${cacheDir.path}/$cacheKey.$extName';
      await File(tmpPath).rename(finalPath);
      onProgress?.call(1);
      return DecodedAudio(
        path: finalPath,
        extension: extName,
        fromCache: false,
      );
    } finally {
      await raf.close();
    }
  }

  /// 清理解密缓存（设置页「清理数据」时调用）。
  Future<int> clearCache() async {
    final dir = Directory(
      '${(await getTemporaryDirectory()).path}/local_audio_cache',
    );
    if (!await dir.exists()) return 0;
    var bytes = 0;
    await for (final e in dir.list()) {
      if (e is File) {
        bytes += await e.length();
        await e.delete();
      }
    }
    return bytes;
  }
}

/// 解析出的 KGM 文件头。
class KgmHeader {
  const KgmHeader({
    required this.headerLen,
    required this.key,
    required this.isVpr,
  });

  /// 音频数据起始偏移。
  final int headerLen;

  /// 17 字节密钥（第 17 字节恒为 0）。
  final Uint8List key;

  /// 是否为 VPR 变体（多一层掩码）。
  final bool isVpr;
}

/// 解码结果。
class DecodedAudio {
  const DecodedAudio({
    required this.path,
    required this.extension,
    required this.fromCache,
  });

  /// 可直接交给 `just_audio` 的本地文件路径。
  final String path;

  /// 真实音频格式（mp3 / flac / ogg / wav / m4a）。
  final String extension;

  /// 是否命中缓存（未重新解密）。
  final bool fromCache;

  Uri get uri => Uri.file(path);
}

/// 解码失败（消息可直接展示给用户）。
class KgmDecodeException implements Exception {
  KgmDecodeException(this.message);
  final String message;

  @override
  String toString() => message;
}
