import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class SearchHistoryService {
  static final SearchHistoryService _instance =
      SearchHistoryService._internal();
  factory SearchHistoryService() => _instance;
  SearchHistoryService._internal();

  static const _fileName = 'search_history.json';
  static const int _maxCount = 20;

  List<String> _history = [];
  List<String> get history => List.unmodifiable(_history);

  Future<void> init() async {
    await _load();
  }

  Future<void> _load() async {
    try {
      final file = await _getFile();
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString());
      if (json is List) {
        _history = json.map((e) => e.toString()).toList();
      }
    } catch (_) {}
  }

  Future<void> add(String keyword) async {
    final k = keyword.trim();
    if (k.isEmpty) return;
    _history.remove(k);
    _history.insert(0, k);
    if (_history.length > _maxCount) {
      _history = _history.sublist(0, _maxCount);
    }
    await _save();
  }

  Future<void> remove(String keyword) async {
    _history.remove(keyword);
    await _save();
  }

  Future<void> clear() async {
    _history = [];
    await _save();
  }

  Future<File> _getFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  Future<void> _save() async {
    try {
      final file = await _getFile();
      await file.writeAsString(jsonEncode(_history));
    } catch (_) {}
  }
}