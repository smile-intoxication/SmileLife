#!/usr/bin/env bash
#
# 一条命令走完「改代码 → 自检 → 提交 → 编译 → 打包 → 上传 TestFlight」。
#
# 为什么必须脚本化：这套流程**手工做过、漏过一步** ——
# 改了代码、推了 main，但忘了推 tag，于是 TestFlight 上还是旧包，
# 而 main 的编译检查是绿的，看起来一切正常。把顺序固定下来就不会漏。
#
# 用法：
#   bash ci/ship.sh "提交信息"            # tag 自动递增（v1.5 → v1.6）
#   bash ci/ship.sh "提交信息" v2.0       # 也可以指定 tag
#
# ⚠️ 从 PowerShell 调 Git Bash 时，嵌套引号**非常容易被吃掉**：
#   实测 `bash ci/ship.sh "加 ci/ship.sh: 一条命令…"` 传进来只剩一个「加」字，
#   提交信息被截断（而且不会有任何报错）。
#   所以**推荐**用文件传提交信息 —— 用编辑器/写文件工具落盘，完全不经过 shell 转义：
#
#     printf '%s' "提交信息" > .git/SHIP_MSG
#     bash ci/ship.sh
#
#   `.git/SHIP_MSG` 在 .git 目录里，永远不会被提交，用完自动删除。
#
# 退出码 0 = main 和 tag 都推成功；非 0 = 中途失败（看输出，未推送的部分不会假装成功）

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

MSG_FILE=".git/SHIP_MSG"

# 提交信息来源，按优先级：第一个参数 > 环境变量 SHIP_MSG > 文件 .git/SHIP_MSG
MSG="${1:-${SHIP_MSG:-}}"
if [ -z "$MSG" ] && [ -f "$MSG_FILE" ]; then
  MSG=$(cat "$MSG_FILE")
fi
TAG="${2:-${SHIP_TAG:-}}"

if [ -z "$MSG" ]; then
  echo '用法: bash ci/ship.sh "提交信息" [tag]' >&2
  echo '  或:  printf %s "提交信息" > .git/SHIP_MSG && bash ci/ship.sh' >&2
  exit 2
fi
# 提交信息只有一个词通常是引号被吃掉了，直接拦下来而不是写进历史
case "$MSG" in
  *" "*) ;;
  *)
    echo "⚠️ 提交信息看起来被截断了（只有「$MSG」一个词）。" >&2
    echo "   这几乎一定是 shell 引号问题 —— 改用 .git/SHIP_MSG 文件传，见上面用法。" >&2
    exit 2
    ;;
esac

# ---------- 1. 自检（不过就中止，绝不推送） ----------
echo "==> 1/5 结构性自检"
if ! bash ci/verify-project.sh; then
  echo "" >&2
  echo "自检未通过，已中止 —— 没有推送任何东西。" >&2
  exit 1
fi

# ---------- 2. 提交 ----------
echo "==> 2/5 提交"
git add -A
if git diff --cached --quiet; then
  echo "    没有待提交的改动，沿用当前 HEAD"
else
  git commit -m "$MSG" || exit 1
fi
# 用完就删，避免下次误用同一条信息
rm -f "$MSG_FILE"
HEAD_SHA=$(git rev-parse --short HEAD)
echo "    HEAD = $HEAD_SHA"
echo "    信息 = $MSG"

# ---------- 3. 推 main → 触发「编译检查」 ----------
echo "==> 3/5 推 main（触发编译检查 job）"
git push origin main || exit 1

# ---------- 4. 打 tag 并推 → 触发「打包并上传 TestFlight」----------
# ⚠️ 这一步和上一步是**两个不同的 job**：只推 main 不会上传。
if [ -z "$TAG" ]; then
  LAST=$(git tag -l 'v*' | sed 's/^v//' | sort -V | tail -1)
  if [ -z "$LAST" ]; then
    TAG="v1.0"
  else
    TAG="v$(printf '%s' "$LAST" | awk -F. '{ printf "%d.%d", $1, $2 + 1 }')"
  fi
fi
echo "==> 4/5 推 tag $TAG（触发打包并上传 TestFlight job）"
git tag -f "$TAG" || exit 1
git push -f origin "$TAG" || exit 1

# ---------- 5. 收尾提示 ----------
echo "==> 5/5 已推送"
echo "    main : $HEAD_SHA"
echo "    tag  : $TAG"
echo ""
echo "接下来查结果（⚠️ 未认证 API 限速 60 次/小时，轮询间隔至少 25 秒）："
echo "  run 列表  https://api.github.com/repos/smile-intoxication/SmileLife/actions/runs"
echo "  失败诊断  https://github.com/smile-intoxication/SmileLife/issues （workflow 自动创建）"
