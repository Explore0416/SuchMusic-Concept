import '../../models/song_model.dart';

/// 跨源歌曲匹配：按「歌名 + 歌手」从候选列表中挑出最匹配的一首。
///
/// 评分规则（[score] 阈值见 [kMatchThreshold]）：
/// - 歌名归一化后**完全一致**：+100；
/// - 歌名归一化后互为包含：+40（仅在以下之一成立时才算匹配）；
/// - 双方歌手集合**有交集**：+50。
///
/// 采用「精确歌名」或「相关歌名 + 歌手交集」（= 40 + 50 = 90）作为匹配门槛，
/// 从而**优先歌名完全一致且歌手有交集**的结果；匹配不到返回 `null`。
const int kMatchThreshold = 90;

/// 从 [candidates] 中为 [target] 挑选最匹配的对端歌曲；无匹配返回 `null`。
SongModel? pickBestMatch(SongModel target, List<SongModel> candidates) {
  final targetName = _normalizeName(target.name);
  if (targetName.isEmpty) return null;
  final targetArtists = _artistTokens(target.artist);

  SongModel? best;
  var bestScore = 0;

  for (final candidate in candidates) {
    final score = _score(targetName, targetArtists, candidate);
    if (score >= kMatchThreshold && score > bestScore) {
      bestScore = score;
      best = candidate;
    }
  }
  return best;
}

int _score(
    String targetName, Set<String> targetArtists, SongModel candidate) {
  final candName = _normalizeName(candidate.name);
  if (candName.isEmpty) return 0;

  int nameScore;
  if (candName == targetName) {
    nameScore = 100;
  } else if (candName.contains(targetName) || targetName.contains(candName)) {
    nameScore = 40;
  } else {
    return 0;
  }

  var score = nameScore;
  final candArtists = _artistTokens(candidate.artist);
  if (targetArtists.isNotEmpty &&
      candArtists.isNotEmpty &&
      targetArtists.intersection(candArtists).isNotEmpty) {
    score += 50;
  }
  return score;
}

/// 歌名归一化：去空白、去常见标点、转小写，便于宽松比较。
String _normalizeName(String raw) => raw
    .toLowerCase()
    .replaceAll(RegExp('''[\\s\\-_·、,，.。!！?？()（）\\[\\]【】"“”’]'''), '');

/// 歌手拆分为 token 集合：按 `/ & , 、 feat 等分隔，逐个归一化。
Set<String> _artistTokens(String raw) {
  final parts = raw
      .toLowerCase()
      .split(RegExp(r'[/&,，、]|feat\.?|ft\.?|\s+'));
  final tokens = <String>{};
  for (final p in parts) {
    final t = _normalizeName(p);
    if (t.isNotEmpty) tokens.add(t);
  }
  return tokens;
}
