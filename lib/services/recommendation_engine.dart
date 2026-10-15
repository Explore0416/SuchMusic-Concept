import 'dart:math' as math;

import '../models/recommendation_profile.dart';
import '../models/song_model.dart';

/// 「猜你想听」多维度打分引擎（设计文档 §5 / §6）。
///
/// ── 设计约定 ─────────────────────────────────────────────────
/// - **纯函数与副作用分离**：`decay/logShare/songScore/artistAffinity/`
///   `genreAffinity/hourAffinity/composeFinal/scoreSong/applyDiversityAndExplore`
///   全部为**顶层纯函数**，输入显式传入、不读时钟、不读 IO → 确定性、可单测。
/// - **优雅降级铁律**：某维度不可用时（无曲风标签 / 无艺人历史）自动从分母剔除
///   对应权重并重新归一化，绝不抛异常。
class RecommendationEngine {
  RecommendationEngine._();

  /// 对候选集打分、排序并做多样性 / 探索打散，返回有序结果。
  static List<Scored> recommend(
    RecommendationInputs inputs,
    RecommendationConfig cfg,
    int limit,
  ) {
    if (limit <= 0 || inputs.candidates.isEmpty) return const <Scored>[];
    final scored = <Scored>[];
    for (final c in inputs.candidates) {
      final score = scoreSong(s: c.features, p: inputs.profile, cfg: cfg);
      scored.add(Scored(
        song: c.song,
        artistKey: c.features.artistKey,
        score: score,
        count: c.features.count,
        tags: c.features.tags,
      ));
    }
    // 分数降序；同分按播放次数降序（稳定、可预期）
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : b.count.compareTo(a.count);
    });
    return applyDiversityAndExplore(ranked: scored, limit: limit, cfg: cfg);
  }

  /// 单曲总分（委托顶层纯函数）。
  static double scoreSong({
    required SongFeatures s,
    required ProfileInputs p,
    required RecommendationConfig cfg,
  }) {
    final songVal = songScore(s, p, cfg);
    final artistVal = artistAffinity(artistKey: s.artistKey, p: p, cfg: cfg);
    final genreVal = genreAffinity(tags: s.tags, p: p, cfg: cfg);
    final timeVal = hourAffinity(s: s, nowHour: p.nowHour, p: p, cfg: cfg);
    final hasGenre = s.tags.isNotEmpty;
    final hasArtist = (p.artistPlays[s.artistKey] ?? 0) > 0;
    return composeFinal(
      s: songVal,
      a: artistVal,
      g: genreVal,
      t: timeVal,
      hasArtist: hasArtist,
      hasGenre: hasGenre,
      cfg: cfg,
    );
  }
}

/// ── 顶层纯函数（设计文档 §4.4 / §5）────────────────────────────

/// 指数时间衰减：`decay(Δt_days, H) = 0.5 ^ (max(0,Δt)/H)`。
///
/// [halfLifeDays] ≤ 0 时返回 0（无意义半衰期视为无衰减信号）。
double decay(double deltaDays, double halfLifeDays) {
  if (halfLifeDays <= 0) return 0.0;
  final d = deltaDays < 0 ? 0.0 : deltaDays;
  return math.pow(0.5, d / halfLifeDays).toDouble();
}

/// 对数抑制的占比：`log(1+x) / log(1+total)`。
///
/// - `total <= 0` → 0（分母 log(1)=0，避免除零/NaN）。
/// - `x <= 0` → 0。
double logShare(int x, int total) {
  if (total <= 0 || x <= 0) return 0.0;
  final denom = math.log(1 + total);
  if (denom <= 0) return 0.0;
  final r = math.log(1 + x) / denom;
  return r.isNaN ? 0.0 : r;
}

/// 以 [hour] 为中心、半径 [radius] 的**环形**小时集合（跨 0 点）。
List<int> hourWindowHours(int hour, int radius) {
  final r = radius < 0 ? 0 : radius;
  final list = <int>[];
  for (var d = -r; d <= r; d++) {
    list.add(((hour + d) % hoursPerDay + hoursPerDay) % hoursPerDay);
  }
  return list;
}

/// 维度①：单曲自身 `S(s)` —— 新鲜度 / 频次 / 完成度。
double songScore(SongFeatures s, ProfileInputs p, RecommendationConfig cfg) {
  final recency = decay(s.daysSinceLastPlay, cfg.halfLifeSongDays);
  final freq = logShare(s.count, p.totalPlays);
  final completion = s.completion.isNaN ? 0.5 : s.completion.clamp(0.0, 1.0);
  final skipRate = s.skipRate.isNaN ? 0.0 : s.skipRate.clamp(0.0, 1.0);
  final quality = completion * (1 - skipRate);
  return 0.45 * recency + 0.30 * freq + 0.25 * quality;
}

/// 维度②：艺人亲和度 `A(s)` —— 含时间衰减与时段偏置。
double artistAffinity({
  required String artistKey,
  required ProfileInputs p,
  required RecommendationConfig cfg,
}) {
  final plays = p.artistPlays[artistKey] ?? 0;
  if (plays <= 0) return 0.0;
  final lastDays = (p.artistLastDays[artistKey] ?? 0).toDouble();
  final decayed = decay(lastDays, cfg.halfLifeArtistDays);
  final share = logShare(plays, p.totalPlays);
  final boost = 1 + cfg.beta * _artistHourShare(artistKey, p, cfg);
  return decayed * share * boost;
}

/// 维度③：曲风亲和度 `G(s)` —— 多标签加权（已过滤 `conf >= tagConfMin`）。
///
/// 无有效标签或标签均无历史 → 返回 0（触发降级归一化）。
double genreAffinity({
  required Map<String, double> tags,
  required ProfileInputs p,
  required RecommendationConfig cfg,
}) {
  if (tags.isEmpty) return 0.0;
  var numer = 0.0;
  var denom = 0.0;
  tags.forEach((tag, conf) {
    if (conf < cfg.tagConfMin) return;
    denom += conf;
    final plays = p.tagPlays[tag] ?? 0;
    if (plays <= 0) return; // 该标签在本机无历史 → 贡献 0
    final lastDays = (p.tagLastDays[tag] ?? 0).toDouble();
    numer += conf * decay(lastDays, cfg.halfLifeGenreDays) * logShare(plays, p.totalPlays);
  });
  if (denom <= 0) return 0.0;
  return numer / denom;
}

/// 维度④：时段 / 情绪亲和度 `T(s,h)` —— 条件概率，缺项在可用项间归一化。
double hourAffinity({
  required SongFeatures s,
  required int nowHour,
  required ProfileInputs p,
  required RecommendationConfig cfg,
}) {
  final window = hourWindowHours(nowHour, cfg.hourWindow);

  final songPlays = s.hourCountAtWindow;
  final tSong = s.count > 0 ? songPlays / s.count : 0.0;

  var acc = 0.4 * tSong;
  var weight = 0.4;

  final artistPlays = p.artistPlays[s.artistKey] ?? 0;
  if (artistPlays > 0) {
    var artistWindow = 0;
    for (final h in window) {
      artistWindow += p.artistPlaysAtHour(s.artistKey, h);
    }
    final tArtist = artistWindow / artistPlays;
    acc += 0.35 * tArtist;
    weight += 0.35;
  }

  // T_tag：按置信度加权平均（仅统计有历史的标签）
  var tagAcc = 0.0;
  var tagWeight = 0.0;
  s.tags.forEach((tag, conf) {
    if (conf < cfg.tagConfMin) return;
    final tagPlays = p.tagPlays[tag] ?? 0;
    if (tagPlays <= 0) return;
    var tagWindow = 0;
    for (final h in window) {
      tagWindow += p.tagPlaysAtHour(tag, h);
    }
    tagAcc += conf * (tagWindow / tagPlays);
    tagWeight += conf;
  });
  if (tagWeight > 0) {
    acc += 0.25 * (tagAcc / tagWeight);
    weight += 0.25;
  }

  return weight <= 0 ? 0.0 : acc / weight;
}

/// 维度⑤ + 总分量纲归一（设计文档 §5.3）。
///
/// `Base = fullW · (Σ_active wᵢ·dimᵢ) / (Σ_active wᵢ)`，
/// `Final = Base + wCross · X`，`X = A·G·T`（无标签则 G=0 → X=0 自动失效）。
///
/// 说明：全维度激活时 `fullW / Σ_active = 1`，退化为**直接加权和**，
/// 与设计文档 §5.6 黄金算例数值一致；降级时按激活维度重新归一化并保持量纲稳定。
double composeFinal({
  required double s,
  required double a,
  required double g,
  required double t,
  required bool hasArtist,
  required bool hasGenre,
  required RecommendationConfig cfg,
}) {
  final fullW = cfg.fullWeightSum;
  var activeW = cfg.wSong + cfg.wTime;
  var weighted = cfg.wSong * s + cfg.wTime * t;
  if (hasArtist) {
    activeW += cfg.wArtist;
    weighted += cfg.wArtist * a;
  }
  if (hasGenre) {
    activeW += cfg.wGenre;
    weighted += cfg.wGenre * g;
  }
  if (activeW <= 0) activeW = cfg.wSong > 0 ? cfg.wSong : 1.0;
  final base = fullW * weighted / activeW;
  final cross = hasGenre ? a * g * t : 0.0;
  return base + cfg.wCross * cross;
}

/// 多样性 / 探索打散（设计文档 §6.2）：
/// 1) 去重；2) 单艺人封顶；3) MMR 打散；4) 探索槽。
List<Scored> applyDiversityAndExplore({
  required List<Scored> ranked,
  required int limit,
  required RecommendationConfig cfg,
}) {
  if (limit <= 0) return const <Scored>[];

  // 1) 去重：按 song.id，再按 (artistKey,name)
  final seenId = <String>{};
  final seenKey = <String>{};
  final pool = <Scored>[];
  for (final r in ranked) {
    if (!seenId.add(r.song.id)) continue;
    final key = '${r.artistKey}\u0000${r.song.name}';
    if (!seenKey.add(key)) continue;
    pool.add(r);
  }

  // 2) + 3) 贪心填充：单艺人封顶 + MMR
  final cap = math.max(1, (cfg.maxArtistShare * limit).ceil());
  final selected = <Scored>[];
  final artistCount = <String, int>{};
  while (selected.length < limit && pool.isNotEmpty) {
    Scored? best;
    var bestAdj = double.negativeInfinity;
    var bestIdx = -1;
    for (var i = 0; i < pool.length; i++) {
      final c = pool[i];
      if ((artistCount[c.artistKey] ?? 0) >= cap) continue;
      final adj = c.score - cfg.mmrLambda * _maxSim(c, selected);
      if (adj > bestAdj) {
        bestAdj = adj;
        best = c;
        bestIdx = i;
      }
    }
    if (best == null) break; // 全部被封顶
    selected.add(best);
    pool.removeAt(bestIdx);
    artistCount[best.artistKey] = (artistCount[best.artistKey] ?? 0) + 1;
  }

  // 4) 探索槽：保证至少 exploreTarget 个「非头部艺人」条目
  final exploreTarget = math.max(1, (cfg.exploreRatio * limit).round());
  _fillExploreSlots(
    selected: selected,
    pool: pool,
    limit: limit,
    exploreTarget: exploreTarget,
    cap: cap,
  );

  return selected;
}

/// ── 引擎入参（供 `PlayHistoryService` 组装）───────────────────

/// 候选曲目 + 其单曲特征。
class CandidateSong {
  const CandidateSong({required this.song, required this.features});

  final SongModel song;
  final SongFeatures features;
}

/// 引擎完整入参。
class RecommendationInputs {
  const RecommendationInputs({
    required this.candidates,
    required this.profile,
  });

  final List<CandidateSong> candidates;
  final ProfileInputs profile;
}

// ── 私有实现 ──────────────────────────────────────────────────

double _artistHourShare(
    String artistKey, ProfileInputs p, RecommendationConfig cfg) {
  final plays = p.artistPlays[artistKey] ?? 0;
  if (plays <= 0) return 0.0;
  var window = 0;
  for (final h in hourWindowHours(p.nowHour, cfg.hourWindow)) {
    window += p.artistPlaysAtHour(artistKey, h);
  }
  return window / plays;
}

/// 与已选集合的最大相似度：同艺人 1.0、同主标签 0.5。
double _maxSim(Scored c, List<Scored> selected) {
  if (selected.isEmpty) return 0.0;
  final mainTag = _mainTag(c.tags);
  var best = 0.0;
  for (final s in selected) {
    if (s.artistKey == c.artistKey) {
      best = math.max(best, 1.0);
      continue;
    }
    if (mainTag != null && _mainTag(s.tags) == mainTag) {
      best = math.max(best, 0.5);
    }
  }
  return best;
}

String? _mainTag(Map<String, double> tags) {
  if (tags.isEmpty) return null;
  String? best;
  var bestConf = double.negativeInfinity;
  tags.forEach((tag, conf) {
    if (conf > bestConf) {
      bestConf = conf;
      best = tag;
    }
  });
  return best;
}

/// 头部艺人（出现过最多次的 artistKey）。
String _topArtist(List<Scored> selected) {
  final counts = <String, int>{};
  for (final s in selected) {
    counts[s.artistKey] = (counts[s.artistKey] ?? 0) + 1;
  }
  var top = '';
  var topCount = -1;
  counts.forEach((k, v) {
    if (v > topCount) {
      topCount = v;
      top = k;
    }
  });
  return top;
}

void _fillExploreSlots({
  required List<Scored> selected,
  required List<Scored> pool,
  required int limit,
  required int exploreTarget,
  required int cap,
}) {
  if (selected.isEmpty || pool.isEmpty) return;

  int exploreCount() {
    final top = _topArtist(selected);
    return selected.where((c) => c.artistKey != top).length;
  }

  final artistCount = <String, int>{};
  for (final s in selected) {
    artistCount[s.artistKey] = (artistCount[s.artistKey] ?? 0) + 1;
  }

  var guard = pool.length + selected.length;
  while (exploreCount() < exploreTarget && pool.isNotEmpty && guard-- > 0) {
    final top = _topArtist(selected);
    // 从池中挑选：新艺人优先、低频其次、得分高者优先
    Scored? cand;
    var candIdx = -1;
    var bestKey = double.negativeInfinity;
    for (var i = 0; i < pool.length; i++) {
      final c = pool[i];
      if (c.artistKey == top) continue;
      if ((artistCount[c.artistKey] ?? 0) >= cap) continue;
      // 新艺人加成 1.0；低频加成 1/count；再叠加得分
      final novelty = (artistCount[c.artistKey] ?? 0) == 0 ? 1.0 : 0.3;
      final lowFreq = 1.0 / (1 + c.count);
      final key = novelty + lowFreq + c.score;
      if (key > bestKey) {
        bestKey = key;
        cand = c;
        candIdx = i;
      }
    }
    if (cand == null) break;
    pool.removeAt(candIdx);

    // 找出被替换的「头部艺人且得分最低」的条目
    Scored? victim;
    var victimIdx = -1;
    var lowest = double.infinity;
    for (var i = 0; i < selected.length; i++) {
      final s = selected[i];
      if (s.artistKey != top) continue;
      if (s.score < lowest) {
        lowest = s.score;
        victim = s;
        victimIdx = i;
      }
    }
    if (victim != null && victimIdx >= 0) {
      artistCount[top] = (artistCount[top] ?? 1) - 1;
      selected[victimIdx] = cand;
      artistCount[cand.artistKey] = (artistCount[cand.artistKey] ?? 0) + 1;
    } else if (selected.length < limit) {
      selected.add(cand);
      artistCount[cand.artistKey] = (artistCount[cand.artistKey] ?? 0) + 1;
    } else {
      break;
    }
  }
}
