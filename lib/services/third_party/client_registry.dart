import 'package:flutter/foundation.dart';

import '../../models/third_party_auth.dart';
import 'remote_clients.dart';

/// Debug 探针 Client（ARCHITECTURE §8.3）。
///
/// 包名固定为 `com.lightningteam.suchmusic.probe`，签名留空 ——
/// 空签名表示「不比对签名」，**只有在 debug 构建下才会被承认**
/// （见 [ClientRegistry] 与 `ThirdPartyAuthService` 的签名校验分支）。
const ThirdPartyClient kDebugProbeClient = ThirdPartyClient(
  clientId: 'debug.suchmusic.probe',
  packageName: 'com.lightningteam.suchmusic.probe',
  signatureSha256: '',
  displayName: 'SuchMusic 调试探针',
);

/// 内置注册表（随 App 发行，不依赖网络）。
///
/// 1.5.1 起白名单主要来自开放平台清单（[RemoteClients]），这里保留是为了：
/// ① 离线 / 验签失败时仍有一份可信基线；② 需要紧急封禁某个 Client 时发版兜底。
/// 签名通过 `keytool -printcert -jarfile x.apk` 取得。
const List<ThirdPartyClient> kBuiltInClients = <ThirdPartyClient>[
  // 示例（接入时按真实签名填写）：
  // ThirdPartyClient(
  //   clientId: 'com.example.player',
  //   packageName: 'com.example.player',
  //   signatureSha256: '<64 位小写 hex>',
  //   displayName: '示例播放器',
  // ),
];

/// 生效的注册表 = 内置 ∪ 远端（同 `client_id` 以远端为准）+ debug 探针。
///
/// 之所以是 getter 而非 `final`：远端清单在启动后才异步就绪，
/// 用 getter 才能让「清单更新后立刻生效」，且 debug 探针只在 `kDebugMode` 下注入。
List<ThirdPartyClient> get kRegisteredClients => mergeClients(
  builtIn: kBuiltInClients,
  remote: RemoteClients.instance.clients,
);

/// 合并内置与远端清单。
///
/// 优先级：远端 > 内置（运营侧改包名 / 签名时不必发版），
/// debug 探针最后强制覆盖（远端不得伪造探针条目）。
/// 结果按 `clientId` 升序稳定排列，空 id 条目被忽略。
@visibleForTesting
List<ThirdPartyClient> mergeClients({
  required Iterable<ThirdPartyClient> builtIn,
  required Iterable<ThirdPartyClient> remote,
  bool includeDebugProbe = kDebugMode,
}) {
  final merged = <String, ThirdPartyClient>{};
  for (final client in builtIn) {
    if (client.clientId.isEmpty) continue;
    merged[client.clientId] = client;
  }
  for (final client in remote) {
    if (client.clientId.isEmpty) continue;
    merged[client.clientId] = client;
  }
  if (includeDebugProbe) {
    merged[kDebugProbeClient.clientId] = kDebugProbeClient;
  }
  final list = merged.values.toList()
    ..sort((a, b) => a.clientId.compareTo(b.clientId));
  return List<ThirdPartyClient>.unmodifiable(list);
}

/// 注册表查询。
///
/// 抽成类是为了让单元测试注入假注册表（真实注册表内容随发版变化，
/// 测试不应依赖具体条目）。
class ClientRegistry {
  /// 固定快照（测试用）。
  const ClientRegistry(List<ThirdPartyClient> clients)
    : _clients = clients,
      _source = null;

  /// 动态视图：每次查询都重新读 [_source]。
  ///
  /// 生产环境用这个，远端清单在启动后异步到达也能立刻生效。
  ClientRegistry.live(List<ThirdPartyClient> Function() source)
    : _clients = const <ThirdPartyClient>[],
      _source = source;

  /// 使用生效注册表（内置 ∪ 远端 + debug 探针）。
  factory ClientRegistry.standard() =>
      ClientRegistry.live(() => kRegisteredClients);

  final List<ThirdPartyClient> _clients;
  final List<ThirdPartyClient> Function()? _source;

  List<ThirdPartyClient> get clients =>
      List<ThirdPartyClient>.unmodifiable(_source?.call() ?? _clients);

  /// 按 clientId 查 Client；未登记返回 null。
  ThirdPartyClient? findById(String clientId) {
    final key = clientId.trim();
    if (key.isEmpty) return null;
    for (final client in clients) {
      if (client.clientId == key) return client;
    }
    return null;
  }

  /// 按包名查 Client；未登记返回 null。
  ThirdPartyClient? findByPackage(String packageName) {
    final key = packageName.trim();
    if (key.isEmpty) return null;
    for (final client in clients) {
      if (client.packageName == key) return client;
    }
    return null;
  }
}

/// 便捷查询：生效注册表按 clientId 查。
ThirdPartyClient? findById(String clientId) =>
    ClientRegistry.standard().findById(clientId);

/// 便捷查询：生效注册表按包名查。
ThirdPartyClient? findByPackage(String packageName) =>
    ClientRegistry.standard().findByPackage(packageName);
