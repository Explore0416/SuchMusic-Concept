#!/usr/bin/env bash
#
# 把构建好的 APK 与更新清单发布到「Cloudflare 分发」链路。
#
#   APK   → 公开仓库 Lightning-technology-team/SuchMusic-Updates 的固定 Release
#           （tag: apk-latest，资源名 SuchMusic-latest.apk），供 Cloudflare Worker
#           边缘代理缓存下载；**不**放进 git，避免仓库膨胀（Pages 也有 25MiB 单文件上限）。
#   清单  → 该仓库 public/update.json，提交后 Cloudflare Pages 自动构建。
#
# 凭据：默认从 ~/.config/suchmusic/release.env 自动加载
#       （UPDATES_TOKEN / CF_API_TOKEN / CF_ZONE_ID），也可用同名环境变量覆盖。
#       该文件权限应为 600，且不得进入代码仓库。
#
# 用法：
#   publish_updates.sh <apk> <versionName> <versionCode> [changelogFile] [keep]
set -euo pipefail

APK_PATH="${1:?usage: publish_updates.sh <apk> <versionName> <versionCode> [changelogFile] [keep]}"
VERSION_NAME="${2:?缺少版本名}"
VERSION_CODE="${3:?缺少版本号}"
CHANGELOG_FILE="${4:-}"
KEEP="${5:-5}"

# 本地凭据：按优先级查找（服务器上由交付方写入，权限 600，不入库）
#   1) $UPDATES_ENV_FILE 显式指定
#   2) 项目根 .env（随项目走，已在 .gitignore 中忽略）
#   3) ~/.config/suchmusic/release.env（机器级，跨项目复用）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE=""
for candidate in "${UPDATES_ENV_FILE:-}" "${PROJECT_ROOT}/.env" "${HOME}/.config/suchmusic/release.env"; do
  if [[ -n "$candidate" && -f "$candidate" ]]; then
    ENV_FILE="$candidate"
    break
  fi
done
if [[ -n "$ENV_FILE" ]]; then
  echo "ℹ️ 读取凭据：${ENV_FILE}"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${UPDATES_TOKEN:?需要设置环境变量 UPDATES_TOKEN，或写入 ${PROJECT_ROOT}/.env / ~/.config/suchmusic/release.env}"

REPO="${UPDATES_REPO:-Lightning-technology-team/SuchMusic-Updates}"
DOMAIN="${UPDATE_DOMAIN:-https://dl.lightning-team.de5.net}"
BRANCH="${UPDATES_BRANCH:-main}"
APK_TAG="${UPDATES_APK_TAG:-apk-latest}"
export GH_TOKEN="$UPDATES_TOKEN"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# 版本号必须严格递增。
# 客户端「检查更新」只比对 versionCode，号不涨就会提示「已是最新」，
# 哪怕 versionName 已经从 1.2.5 变成 1.3.0（这个坑真实发生过）。
echo "▶ 0/4 校验版本号（必须大于线上）"
ONLINE_NAME=""
ONLINE_CODE=0
if ONLINE_JSON="$(curl -s -m 15 "${DOMAIN}/update.json" 2>/dev/null)" && [[ -n "$ONLINE_JSON" ]]; then
  read -r ONLINE_NAME ONLINE_CODE <<<"$(
    python3 -c 'import json,sys
d = json.load(sys.stdin)
print(d.get("versionName", "?"), int(d.get("versionCode") or 0))' <<<"$ONLINE_JSON" 2>/dev/null || echo "? 0"
  )"
fi
[[ "$ONLINE_CODE" =~ ^[0-9]+$ ]] || ONLINE_CODE=0
if (( VERSION_CODE <= ONLINE_CODE )); then
  echo "✖ 版本号不递增：本次 ${VERSION_CODE}，线上 ${ONLINE_NAME}（${ONLINE_CODE}）" >&2
  echo "  客户端只比 versionCode，号不涨会提示「已是最新」。请提升 pubspec 的 build number 后重新构建。" >&2
  exit 1
fi
echo "  ✔ ${ONLINE_NAME:-无}（${ONLINE_CODE}）→ ${VERSION_NAME}（${VERSION_CODE}）"

# 架构闸门：正式包只该含 arm64 的 libflutter.so / libapp.so。
# 漏掉 --target-platform android-arm64 时，Flutter 会把 arm / arm64 / x64
# 三套全打进同一个包，体积从 32MB 涨到 72MB（1.3.0～1.3.3 就是这么胖起来的）。
echo "▶ 0.5/4 校验包体架构（只允许 arm64）"
EXTRA="$(unzip -l "$APK_PATH" 2>/dev/null \
  | awk '/lib\/(armeabi-v7a|x86_64)\/lib(flutter|app)\.so$/ {s+=$1} END {print s+0}')"
if (( EXTRA > 1048576 )); then
  echo "✖ 包里混进了非 arm64 架构（多出 $((EXTRA / 1048576))MB）" >&2
  unzip -l "$APK_PATH" | grep -E "lib/(armeabi-v7a|x86_64)/lib(flutter|app)\.so" >&2
  echo "  请用 scripts/build_release_apk.sh 构建（内含 --target-platform android-arm64）。" >&2
  exit 1
fi
echo "  ✔ 仅 arm64（$(du -h "$APK_PATH" | cut -f1)）"

size_of() { du -h "$1" | cut -f1; }

asset_id() {
  gh api "repos/${REPO}/releases/${RID}/assets?per_page=100" \
    --jq "[.[] | select(.name==\"$1\") | .id][0]" 2>/dev/null || true
}

# 用 curl 直传，不用 gh release upload：
#   gh 在受限网络下会把 72MB 包卡在 0 速率（连接活着但不发数据），
#   而 curl --data-binary 走同一通道能跑满带宽。
upload_asset() {
  local file="$1" name="$2" code
  code=$(curl -sS -m 1800 -o "$WORKDIR/asset.json" -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${UPDATES_TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$file" \
    "https://uploads.github.com/repos/${REPO}/releases/${RID}/assets?name=${name}")
  if [[ "$code" != "201" ]]; then
    echo "✖ 上传 ${name} 失败（HTTP ${code}）" >&2
    head -c 400 "$WORKDIR/asset.json" >&2
    echo >&2
    return 1
  fi
  echo "  ✔ ${name}（$(size_of "$file")）"
}

echo "▶ 1/3 上传安装包到公开 Release（${REPO}@${APK_TAG}）"

RID="$(gh api "repos/${REPO}/releases/tags/${APK_TAG}" --jq '.id' 2>/dev/null || true)"
if [[ -z "$RID" ]]; then
  gh api -X POST "repos/${REPO}/releases" \
    -f tag_name="$APK_TAG" \
    -f name="最新安装包（供 Cloudflare 边缘分发）" \
    -f body="该 Release 的 SuchMusic-latest.apk 始终指向当前内测版安装包，由 Cloudflare Worker 边缘代理缓存后提供下载。" \
    >/dev/null
  RID="$(gh api "repos/${REPO}/releases/tags/${APK_TAG}" --jq '.id')"
fi

# 不用 --clobber：它是「先删旧资源再传新的」，上传多久断链就多久。
# 这里先传临时名，再删旧名、改名，断链窗口压到两次 API 调用之间。
OLD_LATEST="$(asset_id SuchMusic-latest.apk)"
if [[ -n "$OLD_LATEST" ]]; then
  upload_asset "$APK_PATH" "SuchMusic-latest.new.apk"
  gh api -X DELETE "repos/${REPO}/releases/assets/${OLD_LATEST}" >/dev/null
  NEW_ID="$(asset_id SuchMusic-latest.new.apk)"
  gh api -X PATCH "repos/${REPO}/releases/assets/${NEW_ID}" -f name='SuchMusic-latest.apk' >/dev/null
  echo "  ✔ latest 已原子替换（旧资源 ${OLD_LATEST} → 新资源 ${NEW_ID}）"
else
  upload_asset "$APK_PATH" "SuchMusic-latest.apk"
fi

OLD_VER="$(asset_id "SuchMusic-${VERSION_NAME}.apk")"
[[ -n "$OLD_VER" ]] && gh api -X DELETE "repos/${REPO}/releases/assets/${OLD_VER}" >/dev/null
upload_asset "$APK_PATH" "SuchMusic-${VERSION_NAME}.apk"

echo "▶ 2/3 更新更新清单（public/update.json）"

CHANGELOG_TEXT=""
if [[ -n "$CHANGELOG_FILE" && -f "$CHANGELOG_FILE" ]]; then
  CHANGELOG_TEXT="$(cat "$CHANGELOG_FILE")"
fi
VERSION_NAME="$VERSION_NAME" VERSION_CODE="$VERSION_CODE" \
  CHANGELOG_TEXT="$CHANGELOG_TEXT" DOMAIN="$DOMAIN" REPO="$REPO" APK_TAG="$APK_TAG" \
  python3 - "$WORKDIR/update.json" <<'PY'
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

# 用 Contents API 提交，不走 git push：
#   受限网络下 git push 常被 "Connection reset by peer" 打断。
UPDATES_TOKEN="$UPDATES_TOKEN" REPO="$REPO" BRANCH="$BRANCH" \
  MANIFEST="$WORKDIR/update.json" VERSION_NAME="$VERSION_NAME" VERSION_CODE="$VERSION_CODE" \
  python3 - <<'PY'
import base64, json, os, pathlib, urllib.request

token = os.environ["UPDATES_TOKEN"]
repo, branch = os.environ["REPO"], os.environ["BRANCH"]
api = f"https://api.github.com/repos/{repo}/contents/public/update.json"
hdr = {
    "Authorization": f"Bearer {token}",
    "Accept": "application/vnd.github+json",
    "User-Agent": "suchmusic-ci",
}


def call(url, data=None, method="GET"):
    req = urllib.request.Request(url, data=data, headers=hdr, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    return json.load(urllib.request.urlopen(req, timeout=60))


content = pathlib.Path(os.environ["MANIFEST"]).read_bytes()
cur = call(f"{api}?ref={branch}")
if base64.b64decode(cur["content"]) == content:
    print("✔ 清单内容无变化，跳过提交")
else:
    body = json.dumps({
        "message": f"release: v{os.environ['VERSION_NAME']}（build {os.environ['VERSION_CODE']}）",
        "content": base64.b64encode(content).decode(),
        "sha": cur["sha"],
        "branch": branch,
    }).encode()
    res = call(api, data=body, method="PUT")
    print("✔ 已提交清单：", res["commit"]["sha"][:10])
PY

echo "▶ 3/3 清理历史资源（保留最近 ${KEEP} 个版本包）"
mapfile -t ASSETS < <(gh api "repos/${REPO}/releases/${RID}/assets?per_page=100" --jq '.[].name' \
  | grep -E '^SuchMusic-[0-9]+\.[0-9]+\.[0-9]+\.apk$' | sort -rV | tail -n +$((KEEP + 1)) || true)
for a in "${ASSETS[@]:-}"; do
  [ -n "$a" ] || continue
  echo "  清理旧资源：$a"
  gh api -X DELETE "repos/${REPO}/releases/assets/$(asset_id "$a")" >/dev/null
done

# 4/4 清除 Cloudflare 边缘缓存
#     Worker 对 /latest.apk 有 1 小时缓存；不清缓存会「清单已是新版本、下载仍是旧包」。
#     未配置 CF_API_TOKEN / CF_ZONE_ID 时跳过（不影响发布）。
if [ -n "${CF_API_TOKEN:-}" ] && [ -n "${CF_ZONE_ID:-}" ]; then
  echo "▶ 4/4 清除 CF 边缘缓存"
  ok=$(curl -s -m 20 -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"files\":[\"${DOMAIN}/latest.apk\",\"${DOMAIN}/update.json\"]}")
  if grep -q '"success":true' <<<"$ok"; then
    echo "✔ 缓存已清除"
  else
    echo "⚠️ 缓存清除失败（不影响已发布内容）：$(head -c 200 <<<"$ok")"
  fi
else
  echo "ℹ️ 未配置 CF_API_TOKEN/CF_ZONE_ID，跳过缓存清除"
fi

# ▶ 同步 GitHub 代码仓库（概念版）：分支 + tag + Release
#     让项目主页 Releases 页始终显示最新版，用户可从 GitHub 下载 APK。
#     仅在 concept/* 或 sync/* 分支上自动推送分支与 tag；其余分支仅补建 Release。
RELEASE_REPO="${RELEASE_REPO:-Explore0416/SuchMusic-Concept}"
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  CUR="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$CUR" == concept/* || "$CUR" == sync/* ]]; then
    echo "▶ 同步 GitHub 代码仓库（${RELEASE_REPO}）：分支 ${CUR} + tag v${VERSION_NAME}"
    GC="url.https://x-access-token:${UPDATES_TOKEN}@github.com/.insteadOf=https://github.com/"
    if git -c "$GC" push -u origin "$CUR" >/dev/null 2>&1; then
      echo "✔ 已推送分支 ${CUR}"
    else
      echo "⚠️ 分支推送失败，请手动推送（Release 仍会创建）"
    fi
    git tag -f "v${VERSION_NAME}" >/dev/null 2>&1
    if git -c "$GC" push origin "v${VERSION_NAME}" >/dev/null 2>&1; then
      echo "✔ 已推送 tag v${VERSION_NAME}"
    else
      echo "⚠️ tag 推送失败，请手动推送（Release 仍会创建）"
    fi
  fi
  GH_ONLY_VERSION="$VERSION_NAME" RELEASE_REPO="$RELEASE_REPO" RELEASE_BRANCH="$CUR" \
    APK_DIR="$(dirname "$APK_PATH")" \
    bash "$SCRIPT_DIR/create_github_releases.sh" \
    || echo "⚠️ GitHub Release 同步失败，可稍后手动补发（不影响主发布）"
else
  echo "ℹ️ 当前非 git 仓库环境，跳过 GitHub 代码同步"
fi

echo "✔ 完成：清单 ${DOMAIN}/update.json ｜ 安装包 ${DOMAIN}/latest.apk"
