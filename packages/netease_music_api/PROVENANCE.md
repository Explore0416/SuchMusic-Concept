# 来源说明（vendored）

本目录是上游库的 vendored 副本，纳入本仓库版本管理，以保证跨机器可复现构建。

- 来源仓库：https://github.com/hcanyz/flutter-netease-music-api
- 锁定 commit：`989e9ede71410d433792a66c1bafb7cc18133945`
- 版本：0.0.3

## 本仓库补丁（务必保留）

`lib/src/api/play/api.dart`：上游 `playListDetail` / `playListDetailDioMetaData`
缺少 `n` 参数，而本项目调用时传入 `n:`，否则编译报错。补丁内容：

- `playListDetailDioMetaData(String categoryId, {int subCount = 5, int n = 1000})`
  并将函数体内 `'n': 1000,` 改为 `'n': n,`
- `playListDetail(String categoryId, {int subCount = 5, int n = 1000})`
  并将内部调用改为 `playListDetailDioMetaData(categoryId, subCount: subCount, n: n)`
