import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// 应用级异常日志 / 全局兜底服务（单一职责）。
///
/// ### 职责
/// 1. **安装全局异常兜底**（[install]，必须在 `runApp` 之前调用）：
///    - [ErrorWidget.builder]：release 下把整屏灰框（`RenderErrorBox`，
///      `0xF0C0C0C0`）替换为**退化安全**的极简占位 `SizedBox.shrink()`；debug 下保留
///      原有红屏，不牺牲开发可见性（用 [kReleaseMode] 分支）。
///    - [FlutterError.onError]：捕获 build / layout / paint 阶段未捕获异常并记录。
///    - [PlatformDispatcher.onError]：捕获异步 / 引擎层未处理异常，返回 `true`
///      防止进程被杀。
/// 2. **把最近异常落盘**：写入应用支持目录 `last_error.log`（滚动保留最近
///    [maxEntries] 条），便于用户下次复现时拿到确切堆栈。
///
/// ### 隐私
/// 日志**只存本机**，不新增任何上传行为；设置页仅提供**只读**查看 / 复制入口。
///
/// ### 可靠性
/// 所有内部操作均 try/catch —— 本服务自身**永不抛异常**，否则它会成为新的灰屏源。
class CrashLogService {
  CrashLogService._internal();

  static final CrashLogService instance = CrashLogService._internal();

  /// 滚动保留的最近异常条数上限
  static const int maxEntries = 10;

  /// 单条日志落盘时的长度上限（字符），防止超大堆栈撑爆文件
  static const int maxCharsPerEntry = 16000;

  /// 单条记录之间的分隔行
  static const String entrySeparator = '──────────';

  static const String _fileName = 'last_error.log';

  bool _installed = false;

  /// 内存中最近一次异常文本（供 UI 立即展示，无需等待磁盘 IO）
  String? _lastError;

  String? get lastError => _lastError;

  File? _file;

  /// 测试注入：覆盖日志目录（默认取 [getApplicationSupportDirectory]）。
  @visibleForTesting
  Directory? debugDirectoryOverride;

  /// 安装全局兜底（幂等）。必须在 `runApp` 之前调用。
  void install() {
    if (_installed) return;
    _installed = true;

    // 1) build 阶段异常 → 占位 widget（release 极简安全占位 / debug 保留红屏）
    final ErrorWidgetBuilder defaultErrorWidgetBuilder = ErrorWidget.builder;
    ErrorWidget.builder = (FlutterErrorDetails details) {
      unawaited(record(
        details.exception,
        details.stack,
        source: details.library ?? 'widget-build',
      ));
      if (kReleaseMode) {
        // 退化安全：SizedBox.shrink() 为 const widget，构造 / 布局 / 绘制均不会抛异常。
        return const SizedBox.shrink();
      }
      // debug：保留原有红屏，便于开发定位。
      return defaultErrorWidgetBuilder(details);
    };

    // 2) 框架层未捕获异常（build / layout / paint + 无自定义 Zone 的同步异常）
    final FlutterExceptionHandler? previousOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      unawaited(record(
        details.exception,
        details.stack,
        source: details.library ?? 'flutter-framework',
      ));
      // 保留默认呈现（debug 下打印完整日志；release 下为 no-op）。
      if (previousOnError != null) {
        previousOnError(details);
      } else {
        FlutterError.presentError(details);
      }
    };

    // 3) 异步 / 引擎层未处理异常：返回 true 表示已处理，避免进程被杀。
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      unawaited(record(error, stack, source: 'platform-dispatcher'));
      return true;
    };
  }

  /// 记录一条异常（全局钩子内部复用，也便于手动埋点）。
  ///
  /// 返回的 Future 在「内存记录 + 控制台打印」完成后、磁盘写入完成后 resolve；
  /// 钩子内部以 `unawaited` 调用，绝不阻塞主流程。
  Future<void> record(
    Object error,
    StackTrace? stack, {
    String? source,
  }) async {
    try {
      final buffer = StringBuffer();
      if (source != null) buffer.writeln('source: $source');
      buffer.writeln('exception: $error');
      if (stack != null) buffer.writeln('stack:\n$stack');
      var body = buffer.toString();
      if (body.length > maxCharsPerEntry) {
        body = '${body.substring(0, maxCharsPerEntry)}\n...(已截断)';
      }
      final entry = '$entrySeparator\n${_timestamp()}\n$body';
      _lastError = entry;

      // 全量堆栈打印（满足「至少 debugPrint 全量堆栈」）。
      debugPrint('❌ [CrashLog] ${source ?? ''} $error\n$stack');

      await _append(entry);
    } catch (_) {
      // 记录失败也不能抛：兜底吞掉。
    }
  }

  /// 读取全部日志（**只读**）；无日志 / 读取失败时返回空串。
  Future<String> readAll() async {
    try {
      final file = await _resolveFile();
      if (file == null || !await file.exists()) return '';
      return await file.readAsString();
    } catch (_) {
      return '';
    }
  }

  /// 测试用：重置内部缓存（不影响已安装的全局钩子）。
  @visibleForTesting
  void debugReset() {
    _file = null;
    _lastError = null;
    debugDirectoryOverride = null;
  }

  /// 追加一条记录并滚动保留最近 [maxEntries] 条。
  Future<void> _append(String entry) async {
    try {
      final file = await _resolveFile();
      if (file == null) return;

      var existing = '';
      try {
        if (await file.exists()) existing = await file.readAsString();
      } catch (_) {}

      final merged = '$existing$entry';
      final parts = merged
          .split(entrySeparator)
          .where((e) => e.trim().isNotEmpty)
          .toList();
      final kept =
          parts.length > maxEntries ? parts.sublist(parts.length - maxEntries) : parts;
      final out = kept.map((e) => '$entrySeparator$e').join();
      await file.writeAsString(out, flush: true);
    } catch (_) {
      // 写盘失败不影响主流程。
    }
  }

  /// 解析日志文件；目录不可用时返回 null（静默降级）。
  Future<File?> _resolveFile() async {
    if (_file != null) return _file;
    try {
      final Directory dir =
          debugDirectoryOverride ?? await getApplicationSupportDirectory();
      if (!await dir.exists()) await dir.create(recursive: true);
      _file = File('${dir.path}/$_fileName');
      return _file;
    } catch (_) {
      return null;
    }
  }

  String _timestamp() => DateTime.now().toIso8601String();
}
