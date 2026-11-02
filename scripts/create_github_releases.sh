#!/usr/bin/env bash
#
# 在代码仓库 Explore0416/SuchMusic-Concept 补发 v1.3.0 ~ v1.3.5 共 6 个 GitHub Release，
# 每个附对应的 /workspace/SuchMusic-<ver>.apk（发布为 SuchMusic-v<ver>.apk）。
#
# 设计要点：
#   - 用 gh api 创建 / 查询 Release（API 调用成熟稳定）
#   - 用 curl 直传 uploads.github.com 上传 APK，避开 gh release upload 在受限网络下卡死
#   - 仅当查询返回的 id 为纯数字时才视为“已存在”，避免把 404 错误 JSON 当 id
#   - 上传前若同名 asset 已存在则先删除，保证幂等
#   - 检查 curl 上传的 HTTP 状态码，失败即退出
#
# 用法：
#   create_github_releases.sh
set -euo pipefail

REPO="${RELEASE_REPO:-Explore0416/SuchMusic-Concept}"
APK_DIR="${APK_DIR:-/workspace}"
BRANCH="${RELEASE_BRANCH:-concept/1.3.5}"
# 默认补发 1.3.0~1.3.5；接入发布流程时可用 GH_ONLY_VERSION 只处理当前版本
VERSIONS="1.3.0 1.3.1 1.3.2 1.3.3 1.3.4 1.3.5"
[[ -n "${GH_ONLY_VERSION:-}" ]] && VERSIONS="$GH_ONLY_VERSION"

: "${UPDATES_TOKEN:?需要 UPDATES_TOKEN（或 GH_TOKEN）}"
export GH_TOKEN="$UPDATES_TOKEN"
TOKEN="$UPDATES_TOKEN"

is_num() { [[ "$1" =~ ^[0-9]+$ ]]; }

for v in $VERSIONS; do
  tag="v$v"
  apk="$APK_DIR/SuchMusic-$v.apk"
  asset="SuchMusic-v$v.apk"
  if [[ ! -f "$apk" ]]; then
    echo "⚠️ 缺少 $apk，跳过 $tag"
    continue
  fi
  size=$(( $(stat -c %s "$apk") / 1048576 ))
  echo "▶ 处理 $tag（APK ${size}MB）"

  # 查询是否已有 release（仅纯数字 id 才算存在）
  rid="$(gh api "repos/${REPO}/releases/tags/${tag}" --jq '.id' 2>/dev/null || true)"
  if is_num "$rid"; then
    echo "  ℹ️ 复用已存在 Release（$rid）"
  else
    rid="$(gh api -X POST "repos/${REPO}/releases" \
      -f "tag_name=$tag" \
      -f "name=v$v" \
      -f "target_commitish=$BRANCH" \
      -f "body=概念版 v$v 安装包（基于 concept/1.3.5 分支）。" \
      --jq '.id')"
    echo "  ✔ 创建 Release（$rid）"
  fi

  # 幂等：删除同名 asset 再传
  old="$(gh api "repos/${REPO}/releases/${rid}/assets?per_page=100" \
        --jq ".[] | select(.name==\"$asset\") | .id" 2>/dev/null || true)"
  if is_num "$old"; then
    gh api -X DELETE "repos/${REPO}/releases/assets/${old}" >/dev/null 2>&1 || true
  fi

  echo "  ↑ 上传 $asset ..."
  code="$(curl -s -m 900 -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/vnd.android.package-archive" \
    --data-binary "@${apk}" \
    -o /dev/null -w '%{http_code}' \
    "https://uploads.github.com/repos/${REPO}/releases/${rid}/assets?name=${asset}")"
  if [[ "$code" != "201" ]]; then
    echo "  ✗ $tag 上传失败（HTTP $code）"
    exit 1
  fi
  echo "  ✔ $tag 完成（HTTP $code）"
done

echo "🎉 全部 Release 处理完毕"
