import 'dart:async';
import 'dart:typed_data';

import 'package:such_music/models/third_party_auth.dart';
import 'package:such_music/services/third_party/loopback_server.dart';
import 'package:such_music/services/third_party/third_party_bridge.dart';
import 'package:such_music/services/third_party/third_party_data_provider.dart';

/// 单测用的固定 Client（真实注册表随发版变化，测试不应依赖它）。
const String kTestClientId = 'test.client';
const String kTestPackage = 'com.example.test';
const String kTestSignature = 'a1b2c3d4e5f6';

const ThirdPartyClient kTestClient = ThirdPartyClient(
  clientId: kTestClientId,
  packageName: kTestPackage,
  signatureSha256: kTestSignature,
  displayName: '测试客户端',
);

/// 构造 `suchmusic://oauth/authorize` 深链。
Uri authorizeUri({
  String clientId = kTestClientId,
  String package = kTestPackage,
  String scopes = 'genre.read',
  String? state = 'state-1',
  bool silent = false,
}) {
  final query = <String, String>{
    'client_id': clientId,
    'package': package,
    'scopes': scopes,
  };
  if (state != null) query['state'] = state;
  if (silent) query['silent'] = '1';
  return Uri.parse('suchmusic://oauth/authorize').replace(queryParameters: query);
}

/// 一条被投递的静默访问通知（断言用）。
class FakeAccessNotice {
  const FakeAccessNotice({required this.title, required this.content});

  final String title;
  final String content;

  @override
  String toString() => 'FakeAccessNotice($title / $content)';
}

/// 原生桥替身：单测里**不会**触发任何 MethodChannel。
class FakeBridge implements ThirdPartyBridge {
  FakeBridge({
    this.installed = true,
    this.signature = kTestSignature,
    this.callbackSent = true,
    this.launchUri,
  });

  bool installed;

  /// 返回给 Dart 侧的签名（小写 hex）。
  String signature;

  /// 目标包是否有可接收回调的 Activity。
  bool callbackSent;

  /// 冷启动深链。
  String? launchUri;

  /// `getAppIcon` 的返回值（null = 取不到图标，UI 退回首字占位）。
  Uint8List? icon;

  int infoCalls = 0;
  final List<Map<String, Object?>> callbacks = <Map<String, Object?>>[];

  /// `openUrl` 被调用的地址（Web 客户端授权回跳）。
  final List<String> openedUrls = <String>[];

  /// 模拟「没有可用浏览器」：置 false 后 openUrl 返回 false。
  bool browserAvailable = true;

  /// 收到的静默访问通知（按调用顺序）。
  final List<FakeAccessNotice> notices = <FakeAccessNotice>[];
  final StreamController<String> _links = StreamController<String>.broadcast();

  Map<String, Object?>? get lastCallback =>
      callbacks.isEmpty ? null : callbacks.last;

  @override
  Future<InstalledAppInfo> getInstalledAppInfo(String packageName) async {
    infoCalls++;
    if (!installed) return InstalledAppInfo.notInstalled;
    return InstalledAppInfo(
      installed: true,
      label: '测试客户端',
      signatureSha256: signature,
      versionName: '1.0.0',
    );
  }

  @override
  Future<ClientCallbackResult> sendClientCallback(
    String packageName,
    Map<String, Object?> extras,
  ) async {
    callbacks.add(<String, Object?>{'package': packageName, ...extras});
    if (!callbackSent) return ClientCallbackResult.noCallbackActivity;
    return const ClientCallbackResult(sent: true);
  }

  @override
  Future<bool> openUrl(String url) async {
    openedUrls.add(url);
    return browserAvailable;
  }

  @override
  Future<String?> getLaunchUri() async => launchUri;

  @override
  Future<Uint8List?> getAppIcon(String packageName) async => icon;

  @override
  Future<void> showAccessNotice({
    required String title,
    required String content,
  }) async {
    notices.add(FakeAccessNotice(title: title, content: content));
  }

  @override
  Stream<String> get deepLinks => _links.stream;

  void emitDeepLink(String uri) => _links.add(uri);

  Future<void> dispose() => _links.close();
}

/// Loopback 服替身：授权链路单测不需要真的开端口。
class FakeLoopback implements LoopbackPort {
  FakeLoopback({this.port = 45678});

  int port;
  bool failStart = false;
  int startCalls = 0;
  int stopCalls = 0;
  final List<String> startedClients = <String>[];

  /// 最近一次 start 收到的 PKCE challenge / CORS 白名单（Web 客户端断言用）。
  String? lastCodeChallenge;
  Set<String> lastAllowedOrigins = const <String>{};

  @override
  Future<int> start({
    required String clientId,
    required String code,
    required Set<ThirdPartyScope> scopes,
    required ThirdPartyDataProvider provider,
    bool foregroundConfirmed = false,
    String packageName = '',
    String? codeChallenge,
    Set<String> allowedOrigins = const <String>{},
  }) async {
    startCalls++;
    startedClients.add(clientId);
    lastCodeChallenge = codeChallenge;
    lastAllowedOrigins = allowedOrigins;
    if (failStart) throw StateError('bind failed');
    return port;
  }

  @override
  Future<void> stop(String clientId) async {
    stopCalls++;
  }

  @override
  Future<void> stopAll() async {
    stopCalls++;
  }
}

/// 取数替身：按 scope 返回固定数据，并记录收到的参数。
class FakeProvider implements ThirdPartyDataProvider {
  FakeProvider({Map<ThirdPartyScope, Map<String, dynamic>>? data})
      : data = data ?? _defaultData();

  static Map<ThirdPartyScope, Map<String, dynamic>> _defaultData() =>
      <ThirdPartyScope, Map<String, dynamic>>{
        ThirdPartyScope.genreRead: <String, dynamic>{
          'topGenres': <Map<String, Object?>>[
            <String, Object?>{'tag': '流行', 'weight': 1.0},
          ],
          'sampleSize': 3,
          'updatedAt': 1731600000,
        },
        ThirdPartyScope.urlResolve: <String, dynamic>{
          'url': 'https://example.com/a.mp3',
          'source': 'netease',
          'songId': 's1',
          'resolvedAt': 1731600000,
        },
        ThirdPartyScope.accountToken: <String, dynamic>{
          'platform': 'lite',
          'token': 'token-value',
          'userId': '42',
          'nickname': '昵称',
        },
        ThirdPartyScope.playbackControl: <String, dynamic>{
          'ok': true,
          'action': 'play',
        },
      };

  final Map<ThirdPartyScope, Map<String, dynamic>> data;
  final List<ThirdPartyScope> fetched = <ThirdPartyScope>[];
  final Map<ThirdPartyScope, Map<String, dynamic>?> paramsSeen =
      <ThirdPartyScope, Map<String, dynamic>?>{};

  /// 非空时 fetch 直接抛出该异常（模拟 not_logged_in 等）。
  ThirdPartyException? error;

  @override
  Future<Map<String, dynamic>> fetch(
    ThirdPartyScope scope,
    Map<String, dynamic>? params,
  ) async {
    fetched.add(scope);
    paramsSeen[scope] = params;
    final failure = error;
    if (failure != null) throw failure;
    return data[scope] ?? <String, dynamic>{'ok': true};
  }
}
