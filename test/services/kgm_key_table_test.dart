import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/kgm_key_table.dart';

/// 内置密钥表的加载链路回归。
///
/// 这条链路一旦断了（asset 未打进包、pubspec 声明写错、gzip 解压失败），
/// 新版 KGM 会静默退化到旧算法，表现为「所有 .kgg 都解不出」，
/// 而且错误信息里看不出原因——所以必须单独锁住。
void main() {
  testWidgets('rootBundle 能加载并解压 4 MiB 密钥表', (tester) async {
    KgmKeyTable.reset();
    final table = await KgmKeyTable.load();
    expect(table.length, 4 * 1024 * 1024);
    // 表头是 0，与公开的 kugou_key 一致
    expect(table.sublist(0, 16).every((b) => b == 0), isTrue);
  });

  testWidgets('第二次加载走内存缓存（不重复解压）', (tester) async {
    KgmKeyTable.reset();
    final a = await KgmKeyTable.load();
    final b = await KgmKeyTable.load();
    expect(identical(a, b), isTrue);
  });
}
