// M4 授权界面 Widget 测试（ARCHITECTURE §6.3 / §6.7 / 设计规范 §6.8）。
//
// 覆盖：确认页 scope 全量渲染、敏感项标签与警示、拒绝/允许的 pop 值、
// 两个按钮都不是主色实心、已授权 scope 折叠、管理页空态与撤销、设置页入口。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/models/third_party_auth.dart';
import 'package:such_music/screens/settings_page.dart';
import 'package:such_music/screens/third_party_auth_list_page.dart';
import 'package:such_music/screens/third_party_auth_page.dart';
import 'package:such_music/services/third_party/auth_code_service.dart';
import 'package:such_music/services/third_party/client_registry.dart';
import 'package:such_music/services/third_party/third_party_auth_service.dart';
import 'package:such_music/theme/app_theme.dart';
import 'package:such_music/widgets/design_dialog.dart';

import 'support/fake_third_party.dart';

/// 固定屏幕尺寸（逻辑像素），避免默认 800×600 影响布局断言。
void _useSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      debugShowCheckedModeBanner: false,
      home: child,
    );

/// 构造一条待确认请求（默认四项全申请，模拟最严苛的情形）。
AuthRequest _request({
  List<ThirdPartyScope> scopes = const <ThirdPartyScope>[
    ThirdPartyScope.genreRead,
    ThirdPartyScope.accountToken,
    ThirdPartyScope.urlResolve,
    ThirdPartyScope.playbackControl,
  ],
  Set<ThirdPartyScope> granted = const <ThirdPartyScope>{},
  String appLabel = '酷狗助手',
}) =>
    AuthRequest(
      client: kTestClient,
      scopes: scopes,
      state: 'state-1',
      silent: false,
      alreadyGranted: granted,
      appLabel: appLabel,
      signaturePrefix: kTestSignature.substring(0, 8),
    );

/// 把确认页压进一个可观察 pop 值的宿主页面。
Future<void> _pumpAuthPage(WidgetTester tester, AuthRequest request) async {
  _useSize(tester, const Size(390, 900));
  await tester.pumpWidget(
    _host(ThirdPartyAuthPage(request: request, bridge: FakeBridge())),
  );
  await tester.pumpAndSettle();
}

/// 读某个 key 上的 [BoxDecoration]（key 可能落在 Ink / Container 上）。
BoxDecoration _decorationOf(WidgetTester tester, Key key) {
  final target = find.byKey(key);
  final self = tester.widget(target);
  if (self is Ink && self.decoration is BoxDecoration) {
    return self.decoration! as BoxDecoration;
  }
  if (self is Container && self.decoration is BoxDecoration) {
    return self.decoration! as BoxDecoration;
  }
  final descendants = find.descendant(
    of: target,
    matching: find.byType(Container),
  );
  for (final element in descendants.evaluate()) {
    final widget = element.widget as Container;
    if (widget.decoration is BoxDecoration) {
      return widget.decoration! as BoxDecoration;
    }
  }
  fail('$key 下没有找到带 BoxDecoration 的容器');
}

/// 授权服务替身：只接管记录读写，撤销计数与列表状态可控。
class _SpyService extends ThirdPartyAuthService {
  _SpyService(List<ThirdPartyGrant> grants)
      : _grants = List<ThirdPartyGrant>.of(grants),
        super(
          registry: const ClientRegistry(<ThirdPartyClient>[kTestClient]),
          bridge: FakeBridge(),
          codes: AuthCodeService(autoPurge: false),
          server: FakeLoopback(),
          dataProvider: FakeProvider(),
        );

  final List<ThirdPartyGrant> _grants;

  final List<String> revoked = <String>[];
  int revokeAllCalls = 0;

  @override
  Future<List<ThirdPartyGrant>> listGrants() async =>
      List<ThirdPartyGrant>.unmodifiable(_grants);

  @override
  Future<void> revoke(String clientId) async {
    revoked.add(clientId);
    _grants.removeWhere((grant) => grant.clientId == clientId);
  }

  @override
  Future<void> revokeAll() async {
    revokeAllCalls++;
    _grants.clear();
  }
}

ThirdPartyGrant _grant(
  String clientId,
  String packageName,
  Set<ThirdPartyScope> scopes, {
  int lastAccessAt = 1731600000,
}) =>
    ThirdPartyGrant(
      clientId: clientId,
      packageName: packageName,
      scopes: scopes,
      grantedAt: 1731600000,
      lastAccessAt: lastAccessAt,
      callCount: 2,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    DesignToast.debugReset();
  });

  tearDown(DesignToast.debugReset);

  group('授权确认页（§6.3）', () {
    testWidgets('渲染出全部申请 scope 的标题', (tester) async {
      await _pumpAuthPage(tester, _request());

      for (final scope in ThirdPartyScope.values) {
        expect(
          find.text(scope.label),
          findsOneWidget,
          reason: '确认页必须逐项列出「${scope.label}」',
        );
      }
      // 应用名 / 包名 / 引导句
      expect(find.text('酷狗助手'), findsOneWidget);
      expect(find.text(kTestPackage), findsOneWidget);
      expect(find.text('申请访问以下内容'), findsOneWidget);
      expect(find.text('拒绝'), findsOneWidget);
      expect(find.text('允许'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('含 account.token 时出现「敏感」标签与警示文案', (tester) async {
      await _pumpAuthPage(tester, _request());

      expect(find.text('敏感'), findsOneWidget);
      expect(find.text(kThirdPartyTokenWarning), findsOneWidget);

      // 规范禁止用红 / 橙等彩色说明文字：警示必须是墨色常规字重
      final warning = tester.widget<Text>(find.text(kThirdPartyTokenWarning));
      expect(warning.style?.color, AppColors.ink);
      expect(warning.style?.fontWeight, FontWeight.w400);
    });

    testWidgets('不含 account.token 时不出现「敏感」与警示', (tester) async {
      await _pumpAuthPage(
        tester,
        _request(
          scopes: const <ThirdPartyScope>[
            ThirdPartyScope.genreRead,
            ThirdPartyScope.urlResolve,
          ],
        ),
      );

      expect(find.text('敏感'), findsNothing);
      expect(find.text(kThirdPartyTokenWarning), findsNothing);
    });

    testWidgets('已授权的 scope 折叠为一行并可展开', (tester) async {
      await _pumpAuthPage(
        tester,
        _request(
          scopes: const <ThirdPartyScope>[
            ThirdPartyScope.genreRead,
            ThirdPartyScope.urlResolve,
          ],
          granted: const <ThirdPartyScope>{ThirdPartyScope.genreRead},
        ),
      );

      // 折叠行存在，本次新增的 url.resolve 仍在正文里
      expect(find.text('已授权的 1 项'), findsOneWidget);
      expect(find.text('歌曲直链'), findsOneWidget);

      await tester.tap(find.byKey(thirdPartyAuthFoldKey));
      await tester.pumpAndSettle();
      expect(find.text('已授权的 1 项'), findsOneWidget);
      // 展开后曲风画像出现在列表里（此前只有折叠行文字）
      expect(find.text('曲风画像'), findsOneWidget);
    });

    testWidgets('两个按钮都不是主色实心（规范 §6.8 反诱导）', (tester) async {
      await _pumpAuthPage(tester, _request());

      final deny = _decorationOf(tester, thirdPartyAuthDenyKey);
      final allow = _decorationOf(tester, thirdPartyAuthAllowKey);

      for (final decoration in <BoxDecoration>[deny, allow]) {
        final color = decoration.color;
        expect(color, isNotNull);
        expect(color, isNot(AppColors.ink), reason: '不得用墨色实心按钮');
        expect(color, isNot(AppColors.brand), reason: '不得用品牌色实心按钮');
        expect(color, isNot(AppColors.rose));
        expect(color, isNot(AppColors.success));
      }
      // 两者形态可区分但不构成视觉诱导：拒绝是浅底，允许是白底 + 发丝描边
      expect(deny.color, AppColors.surfaceMuted);
      expect(allow.color, AppColors.surface);
      expect(allow.border, isNotNull);
      expect(deny.border, isNull);
    });

    testWidgets('点「拒绝」→ pop(false)', (tester) async {
      _useSize(tester, const Size(390, 900));
      bool? result;
      var popped = false;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<bool>(
                      MaterialPageRoute<bool>(
                        builder: (_) => ThirdPartyAuthPage(
                          request: _request(),
                          bridge: FakeBridge(),
                        ),
                      ),
                    );
                    popped = true;
                  },
                  child: const Text('open-auth'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open-auth'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('拒绝'));
      await tester.pumpAndSettle();

      expect(popped, isTrue);
      expect(result, isFalse);
      expect(find.text('open-auth'), findsOneWidget);
    });

    testWidgets('点「允许」→ pop(true)', (tester) async {
      _useSize(tester, const Size(390, 900));
      bool? result;
      var popped = false;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<bool>(
                      MaterialPageRoute<bool>(
                        builder: (_) => ThirdPartyAuthPage(
                          request: _request(),
                          bridge: FakeBridge(),
                        ),
                      ),
                    );
                    popped = true;
                  },
                  child: const Text('open-auth'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open-auth'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('允许'));
      await tester.pumpAndSettle();

      expect(popped, isTrue);
      expect(result, isTrue);
    });
  });

  group('授权管理页（§6.7）', () {
    testWidgets('空态给出原因与后续说明', (tester) async {
      _useSize(tester, const Size(390, 844));
      await tester.pumpWidget(
        _host(
          ThirdPartyAuthListPage(
            service: _SpyService(const <ThirdPartyGrant>[]),
            registry: const ClientRegistry(<ThirdPartyClient>[kTestClient]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('第三方授权'), findsOneWidget);
      expect(find.text('还没有应用获得授权'), findsOneWidget);
      expect(find.text('第三方应用拉起 SuchMusic 申请数据时会出现在这里'), findsOneWidget);
      expect(find.text('全部撤销'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('撤销：二次确认 → revoke 被调用 → 列表变空', (tester) async {
      _useSize(tester, const Size(390, 844));
      final service = _SpyService(<ThirdPartyGrant>[
        _grant(
          kTestClientId,
          kTestPackage,
          <ThirdPartyScope>{
            ThirdPartyScope.genreRead,
            ThirdPartyScope.urlResolve,
          },
          lastAccessAt: 1731600600,
        ),
        _grant(
          'other.client',
          'com.example.other',
          <ThirdPartyScope>{ThirdPartyScope.playbackControl},
          lastAccessAt: 1731600300,
        ),
      ]);

      await tester.pumpWidget(
        _host(
          ThirdPartyAuthListPage(
            service: service,
            registry: const ClientRegistry(<ThirdPartyClient>[kTestClient]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 两条记录：注册表里有名字的显示展示名，没有的回退包名
      expect(find.text('测试客户端'), findsOneWidget);
      expect(find.text('com.example.other'), findsOneWidget);
      // scope 摘要用「、」连接，不用中点
      expect(find.text('曲风画像、歌曲直链'), findsOneWidget);

      // 撤销第一条
      await tester.tap(find.text('撤销').first);
      await tester.pumpAndSettle();
      expect(find.text(kThirdPartyRevokeConfirmLabel), findsOneWidget);
      await tester.tap(find.text(kThirdPartyRevokeConfirmLabel));
      await tester.pumpAndSettle();

      expect(service.revoked, <String>[kTestClientId]);
      expect(find.text('测试客户端'), findsNothing);
      expect(find.text('com.example.other'), findsOneWidget);

      // 撤销剩下一条 → 列表变空
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kThirdPartyRevokeConfirmLabel));
      await tester.pumpAndSettle();

      expect(service.revoked.length, 2);
      expect(find.text('还没有应用获得授权'), findsOneWidget);

      // 关掉 2s 后自动消失的 toast，避免留下 pending timer
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('全部撤销：清空全部授权', (tester) async {
      _useSize(tester, const Size(390, 844));
      final service = _SpyService(<ThirdPartyGrant>[
        _grant(kTestClientId, kTestPackage, <ThirdPartyScope>{
          ThirdPartyScope.genreRead,
        }),
        _grant('other.client', 'com.example.other', <ThirdPartyScope>{
          ThirdPartyScope.urlResolve,
        }),
      ]);

      await tester.pumpWidget(
        _host(
          ThirdPartyAuthListPage(
            service: service,
            registry: const ClientRegistry(<ThirdPartyClient>[kTestClient]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('全部撤销'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kThirdPartyRevokeConfirmLabel));
      await tester.pumpAndSettle();

      expect(service.revokeAllCalls, 1);
      expect(find.text('还没有应用获得授权'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('设置页入口', () {
    testWidgets('「数据」分组里有「第三方授权」入口', (tester) async {
      _useSize(tester, const Size(430, 1400));
      await tester.pumpWidget(_host(const SettingsPage()));
      await tester.pumpAndSettle();

      expect(find.text('第三方授权'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
