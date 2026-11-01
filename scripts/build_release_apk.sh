#!/usr/bin/env bash
#
# 构建发布用 APK（只含 arm64-v8a）。
#
# 为什么要单独一个脚本：
#   `flutter build apk` 的默认 target-platform 是
#   android-arm,android-arm64,android-x64，而且 Flutter Gradle Plugin 会
#   **清空并覆盖** android/app/build.gradle.kts 里的 ndk.abiFilters —— 于是
#   三套 libflutter.so / libapp.so 全被打进包里，包体从 32MB 涨到 72MB。
#   这个坑真实发生过：1.3.0～1.3.3 四个版本都是 70MB+。
#
# 用法：
#   build_release_apk.sh [输出路径]
#   默认输出 /workspace/SuchMusic-<versionName>.apk
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

VERSION_NAME="$(sed -n 's/^version: \([^+]*\)+.*/\1/p' pubspec.yaml)"
VERSION_CODE="$(sed -n 's/^version: [^+]*+\([0-9]*\).*/\1/p' pubspec.yaml)"
if [[ -z "$VERSION_NAME" || -z "$VERSION_CODE" ]]; then
  echo "✖ 读不到 pubspec.yaml 的 version" >&2
  exit 1
fi

OUT="${1:-/workspace/SuchMusic-${VERSION_NAME}.apk}"

echo "▶ 构建 ${VERSION_NAME}（${VERSION_CODE}）· arm64-v8a only"
flutter build apk --release --target-platform android-arm64

cp build/app/outputs/flutter-apk/app-release.apk "$OUT"

# 体积闸门：arm64 单架构正常在 32MB 上下，超过 40MB 基本可以肯定又混进了
# v7a / x86_64 的 libflutter.so（单个就有 8～13MB）。
SIZE=$(stat -c %s "$OUT")
if (( SIZE > 41943040 )); then
  echo "✖ 包体 $((SIZE / 1048576))MB 超过 40MB，检查是否漏了 --target-platform" >&2
  unzip -l "$OUT" | grep -E "lib/(armeabi-v7a|x86_64)/lib(flutter|app)\.so" >&2 || true
  exit 1
fi

echo "  ✔ ${OUT}（$((SIZE / 1048576))MB）"
sha256sum "$OUT"
