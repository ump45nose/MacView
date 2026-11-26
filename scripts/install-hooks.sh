#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -gt 1 ]; then
  echo "用法：scripts/install-hooks.sh [新历史根提交]" >&2
  exit 2
fi

main_root=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
hooks="$main_root/scripts/git-hooks"
if [ ! -x "$hooks/pre-push" ] || [ ! -x "$main_root/scripts/privacy-check" ]; then
  echo "主工作区缺少隐私检查或钩子，请先合入发布准备代码" >&2
  exit 2
fi
if [ "$#" -eq 1 ]; then
  root=$(git rev-parse --verify --end-of-options "$1^{commit}" 2>/dev/null) || { echo "根提交不存在" >&2; exit 2; }
  if [ "$(git rev-list --max-parents=0 "$root")" != "$root" ]; then
    echo "指定提交不是历史根提交" >&2
    exit 2
  fi
else
  root=$(git rev-list --max-parents=0 main 2>/dev/null) || { echo "main 的根提交不存在" >&2; exit 2; }
fi
if [[ ! "$root" =~ ^[0-9a-f]{40,64}$ ]]; then
  echo "必须指定唯一的历史根提交" >&2
  exit 2
fi
git config --local macview.historyRoot "$root"
git config --local core.hooksPath "$hooks"
echo "已安装主工作区推送前钩子，并记录历史根提交"
