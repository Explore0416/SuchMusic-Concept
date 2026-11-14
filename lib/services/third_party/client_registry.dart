import 'package:flutter/foundation.dart';

import '../../models/third_party_auth.dart';

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

/// 正式注册表（release 构建可见）。
///
/// 接入新 Client 的唯一动作 = 在此追加一条 `ThirdPartyClient` 并发版（ARCH §8.3）。
/// 目前尚无正式接入方，故为空；签名通过 `keytool -printcert -jarfile x.apk` 取得。
const List<ThirdPartyClient> kBuiltInClients = <ThirdPartyClient>[
  // 示例（接入时按真实签名填写）：
  // ThirdPartyClient(
  //   clientId: 'com.example.player',
  //   packageName: 'com.example.player',
  //   signatureSha256: '<64 位小写 hex>',
  //   displayName: '示例播放器',
  // ),
];

/// 生效的注册表。
///
/// 之所以是 `final` 而非 `const`：debug 探针只在 `kDebugMode` 下注入，
/// const 列表字面量无法表达条件元素（ARCH §8.3 要求 release 不包含探针）。
final List<ThirdPartyClient> kRegisteredClients = <ThirdPartyClient>[
  ...kBuiltInClients,
  if (kDebugMode) kDebugProbeClient,
];

/// 注册表查询。
///
/// 抽成类是为了让单元测试注入假注册表（真实注册表内容随发版变化，
/// 测试不应依赖具体条目）。
class ClientRegistry {
  const ClientRegistry(this._clients);

  /// 使用内置注册表（debug 下含探针）。
  factory ClientRegistry.standard() => ClientRegistry(kRegisteredClients);

  final List<ThirdPartyClient> _clients;

  List<ThirdPartyClient> get clients => List<ThirdPartyClient>.unmodifiable(_clients);

  /// 按 clientId 查 Client；未登记返回 null。
  ThirdPartyClient? findById(String clientId) {
    final key = clientId.trim();
    if (key.isEmpty) return null;
    for (final client in _clients) {
      if (client.clientId == key) return client;
    }
    return null;
  }

  /// 按包名查 Client；未登记返回 null。
  ThirdPartyClient? findByPackage(String packageName) {
    final key = packageName.trim();
    if (key.isEmpty) return null;
    for (final client in _clients) {
      if (client.packageName == key) return client;
    }
    return null;
  }
}

/// 便捷查询：内置注册表按 clientId 查。
ThirdPartyClient? findById(String clientId) =>
    ClientRegistry.standard().findById(clientId);

/// 便捷查询：内置注册表按包名查。
ThirdPartyClient? findByPackage(String packageName) =>
    ClientRegistry.standard().findByPackage(packageName);
