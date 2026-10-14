#!/usr/bin/env bash
#
# 从 CHANGELOG.md 提取指定版本的章节，用于 CI 生成 Release 更新日志。
#
# 用法：changelog_extract.sh <version> [file]
#   <version>  版本号，如 0.9.0（不带 v 前缀）
#   [file]     CHANGELOG 路径，默认 CHANGELOG.md
#
# 行为：输出 `## [<version>]` 到下一个二级标题（`## `）之间的内容；
#       未找到则输出空、退出码 0。
set -euo pipefail

version="${1:?usage: changelog_extract.sh <version> [file]}"
file="${2:-CHANGELOG.md}"

if [[ ! -f "$file" ]]; then
  exit 0
fi

awk -v ver="$version" '
  $0 ~ "^## \\[" ver "\\]" { inside = 1; next }
  inside && /^## / { exit }
  inside { print }
' "$file"
