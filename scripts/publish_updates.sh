#!/usr/bin/env bash
#
# 把构建好的 APK 与更新清单发布到「Cloudflare 分发」链路。
#
#   APK   → 公开仓库 Lightning-technology-team/SuchMusic-Updates 的固定 Release
#           （tag: apk-latest，资源名 SuchMusic-latest.apk），供 Cloudflare Worker
#           边缘代理缓存下载；**不**放进 git，避免仓库膨胀（Pages 也有 25MiB 单文件上限）。
#   清单  → 该仓库 public/update.json，推送后 Cloudflare Pages 自动构建。
#
# 用法：
#   UPDATES_TOKEN=<token> publish_updates.sh <apk> <versionName> <versionCode> [changelogFile] [keep]
set -euo pipefail

APK_PATH="${1:?usage: publish_updates.sh <apk> <versionName> <versionCode> [changelogFile] [keep]}"
VERSION_NAME="${2:?缺少版本名}"
VERSION_CODE="${3:?缺少版本号}"
CHANGELOG_FILE="${4:-}"
KEEP="${5:-5}"

: "${UPDATES_TOKEN:?需要设置环境变量 UPDATES_TOKEN}"

REPO="${UPDATES_REPO:-Lightning-technology-team/SuchMusic-Updates}"
DOMAIN="${UPDATE_DOMAIN:-https://dl.lightning-team.de5.net}"
BRANCH="${UPDATES_BRANCH:-main}"
APK_TAG="${UPDATES_APK_TAG:-apk-latest}"
export GH_TOKEN="$UPDATES_TOKEN"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "▶ 1/3 上传安装包到公开 Release（${REPO}@${APK_TAG}）"
if gh release view "$APK_TAG" --repo "$REPO" >/dev/null 2>&1; then
  cp "$APK_PATH" "$WORKDIR/SuchMusic-latest.apk"
  gh release upload "$APK_TAG" "$WORKDIR/SuchMusic-latest.apk" --repo "$REPO" --clobber
else
  gh release create "$APK_TAG" --repo "$REPO" \
    --title "最新安装包（供 Cloudflare 边缘分发）" \
    --notes "该 Release 的 SuchMusic-latest.apk 始终指向当前内测版安装包，由 Cloudflare Worker 边缘代理缓存后提供下载。" \
    "$WORKDIR/SuchMusic-latest.apk"
fi
cp "$APK_PATH" "$WORKDIR/SuchMusic-${VERSION_NAME}.apk"
gh release upload "$APK_TAG" "$WORKDIR/SuchMusic-${VERSION_NAME}.apk" --repo "$REPO" --clobber

echo "▶ 2/3 更新更新清单（public/update.json）"
git clone --depth 1 --branch "$BRANCH" \
  "https://x-access-token:${UPDATES_TOKEN}@github.com/${REPO}.git" "$WORKDIR/repo"
mkdir -p "$WORKDIR/repo/public"

# 只保留最近 KEEP 个历史版本资源，避免无限增长
mapfile -t ASSETS < <(gh release view "$APK_TAG" --repo "$REPO" --json assets \
  --jq '.assets[].name' | grep -E '^SuchMusic-v' | sort -rV | tail -n +$((KEEP + 1)) || true)
for a in "${ASSETS[@]:-}"; do
  [ -n "$a" ] && { echo "  清理旧资源：$a"; gh release delete-asset "$APK_TAG" "$a" --repo "$REPO" --yes >/dev/null; }
done

CHANGELOG_TEXT=""
if [[ -n "$CHANGELOG_FILE" && -f "$CHANGELOG_FILE" ]]; then
  CHANGELOG_TEXT="$(cat "$CHANGELOG_FILE")"
fi
VERSION_NAME="$VERSION_NAME" VERSION_CODE="$VERSION_CODE" \
  CHANGELOG_TEXT="$CHANGELOG_TEXT" DOMAIN="$DOMAIN" REPO="$REPO" APK_TAG="$APK_TAG" \
  python3 - "$WORKDIR/repo/public/update.json" <<'PY'
import json, os, pathlib, sys

target = pathlib.Path(sys.argv[1])
log = os.environ.get('CHANGELOG_TEXT', '').strip()
payload = {
    "versionName": os.environ["VERSION_NAME"],
    "versionCode": int(os.environ["VERSION_CODE"]),
    "force": False,
    # 主链路：Cloudflare Worker（国内走 CF 加速）
    "cf": f'{os.environ["DOMAIN"]}/latest.apk',
    # 兜底：公开仓库的 Release 资源（GitHub 直连）
    "github": (
        f'https://github.com/{os.environ["REPO"]}/releases/download/'
        f'{os.environ["APK_TAG"]}/SuchMusic-latest.apk'
    ),
    "changelog": log,
}
target.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding='utf-8')
print(target.read_text(encoding='utf-8'))
PY

echo "▶ 3/3 提交并推送（触发 Cloudflare Pages 构建）"
cd "$WORKDIR/repo"
git add -A
if git diff --cached --quiet; then
  echo "✔ 清单无变化，跳过提交"
else
  git -c user.name='suchmusic-ci' -c user.email='ci@users.noreply.github.com' \
    commit -q -m "release: v${VERSION_NAME}（build ${VERSION_CODE}）"
  git push -q origin "$BRANCH"
fi
echo "✔ 完成：清单 ${DOMAIN}/update.json ｜ 安装包 ${DOMAIN}/latest.apk"
