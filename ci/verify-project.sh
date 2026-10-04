#!/usr/bin/env bash
#
# 结构性自检 —— **不需要 Xcode / Mac**，本地 Git Bash 和 CI 都能跑。
#
# 它验证的是「不变量」：那些**编译通过也不代表正确**、出错又会静默很久的东西。
# 每一条都对应一个真实踩过的坑（见 AGENTS.md）。
#
# ⚠️ 可移植性要求：必须在 **macOS runner 的 /bin/bash 3.2** 上也能跑。
#    因此禁止使用 bash 4+ 特性（mapfile / 关联数组 / ${var,,} 等），
#    也不要用 GNU sed 的 addr,+N 这种扩展语法。
#
# 用法：
#   bash ci/verify-project.sh
#
# 退出码 0 = 全部通过；非 0 = 有失败项（CI 会因此变红）。

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

PASS=0
FAIL=0

ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
section() { printf '\n== %s\n' "$1"; }

# 把文件里的**注释**去掉再判断。
# 为什么需要：解释性注释里提到 replaceItemAt / fatalError 是**好事**（说明写清楚了坑），
# 不该被当成违规。否则守卫会误报，久而久之就没人信它了。
code_only() {
  if [ "$#" -gt 0 ]; then
    sed -e 's://.*::' "$1" 2>/dev/null
  else
    sed -e 's://.*::'
  fi
}

# ---------- 1. App Group 标识符必须三处一致 ----------
section "1. App Group 标识符一致性"
CODE_GROUP=$(grep -oE '"group\.[^"]+"' watch/Shared/SharedContainer.swift 2>/dev/null | head -1 | tr -d '"')
WATCH_GROUP=$(grep -oE '<string>group\.[^<]+</string>' watch/WatchApp.entitlements 2>/dev/null | head -1 | sed -e 's|<string>||' -e 's|</string>||')
WIDGET_GROUP=$(grep -oE '<string>group\.[^<]+</string>' watch/Widget.entitlements 2>/dev/null | head -1 | sed -e 's|<string>||' -e 's|</string>||')

printf '       SharedContainer.swift : %s\n' "${CODE_GROUP:-（没找到）}"
printf '       WatchApp.entitlements : %s\n' "${WATCH_GROUP:-（没找到）}"
printf '       Widget.entitlements   : %s\n' "${WIDGET_GROUP:-（没找到）}"

if [ -z "$CODE_GROUP" ] || [ -z "$WATCH_GROUP" ] || [ -z "$WIDGET_GROUP" ]; then
  bad "有文件里找不到 App Group 标识符"
elif [ "$CODE_GROUP" = "$WATCH_GROUP" ] && [ "$CODE_GROUP" = "$WIDGET_GROUP" ]; then
  ok "三处完全一致"
else
  bad "三处不一致！这不会编译报错，但小组件会永远读不到数据"
fi

# ---------- 2. Bundle ID 关系 ----------
section "2. Bundle ID 关系"
IDS=$(grep -oE 'PRODUCT_BUNDLE_IDENTIFIER: [A-Za-z0-9.]+' project.yml | awk '{print $2}')
IOS_ID=$(printf '%s\n' "$IDS" | grep -vE '\.watchkitapp' | head -1)
WATCH_ID=$(printf '%s\n' "$IDS" | grep -E '\.watchkitapp$' | head -1)
WIDGET_ID=$(printf '%s\n' "$IDS" | grep -E '\.watchkitapp\.widget$' | head -1)
COMPANION=$(grep -oE 'WKCompanionAppBundleIdentifier: [A-Za-z0-9.]+' project.yml | awk '{print $2}')

printf '       iOS    : %s\n' "${IOS_ID:-（没找到）}"
printf '       watch  : %s\n' "${WATCH_ID:-（没找到）}"
printf '       widget : %s\n' "${WIDGET_ID:-（没找到）}"

if [ -z "$IOS_ID" ] || [ -z "$WATCH_ID" ] || [ -z "$WIDGET_ID" ]; then
  bad "三个 PRODUCT_BUNDLE_IDENTIFIER 没凑齐（应有 iOS / .watchkitapp / .watchkitapp.widget）"
else
  case "$WATCH_ID" in "$IOS_ID".watchkitapp) ok "watch app 挂在 iOS app 之下" ;; *) bad "watch app 的 bundle id 不是 <iOS>.watchkitapp" ;; esac
  case "$WIDGET_ID" in "$WATCH_ID".widget) ok "widget 挂在 watch app 之下" ;; *) bad "widget 的 bundle id 不是 <watch>.widget" ;; esac
fi

if [ -n "$COMPANION" ] && [ "$COMPANION" = "$IOS_ID" ]; then
  ok "WKCompanionAppBundleIdentifier 指向 iOS app"
else
  bad "WKCompanionAppBundleIdentifier（${COMPANION:-空}）与 iOS bundle id（${IOS_ID:-空}）不一致"
fi

# ---------- 3. project.yml 引用的路径必须都存在 ----------
section "3. project.yml 引用的路径"
MISSING=0
for p in $(grep -oE '\- path: [^ ]+' project.yml | sed 's/- path: //'); do
  if [ ! -e "$p" ]; then
    bad "路径不存在：$p"
    MISSING=$((MISSING + 1))
  fi
done
[ "$MISSING" -eq 0 ] && ok "全部存在"

# ---------- 4. 隐私清单 ----------
section "4. 隐私清单（缺了 App Store Connect 会直接拒收）"
for f in watch/PrivacyInfo.xcprivacy watch/Widget/PrivacyInfo.xcprivacy ios/PrivacyInfo.xcprivacy; do
  if [ ! -f "$f" ]; then
    bad "缺少 $f"
  elif ! head -2 "$f" | grep -q '<?xml'; then
    bad "$f 不像合法 XML"
  else
    ok "$f 存在且看起来是 XML"
  fi
done

if grep -q 'NSPrivacyAccessedAPICategoryUserDefaults' watch/PrivacyInfo.xcprivacy 2>/dev/null \
   && grep -q 'CA92.1' watch/PrivacyInfo.xcprivacy 2>/dev/null; then
  ok "手表 app 声明了 UserDefaults / CA92.1"
else
  bad "watch/PrivacyInfo.xcprivacy 没声明 UserDefaults / CA92.1（而代码里用了 UserDefaults.standard）"
fi

for f in watch/PrivacyInfo.xcprivacy watch/Widget/PrivacyInfo.xcprivacy ios/PrivacyInfo.xcprivacy; do
  if grep -q -- "- path: $f" project.yml; then
    ok "project.yml 已把 $f 接进 target"
  else
    bad "project.yml 没有引用 $f —— 文件存在但不会进 bundle"
  fi
done

# ---------- 5. 版本号可覆盖性 ----------
section "5. 版本号可覆盖性"
for key in CFBundleShortVersionString CFBundleVersion; do
  n=$(grep -c "$key: \"\$(" project.yml)
  if [ "$n" -ge 3 ]; then
    ok "$key 在 3 个 target 里都指向 \$(...)"
  else
    bad "$key 只出现 $n 次（应为 3）。不显式写的话 XcodeGen 会硬编码成 \"1.0\"/\"1\"，改版本号对产物无效"
  fi
done

# ---------- 6. 已知反模式回归守卫（只看代码，不看注释） ----------
section "6. 已知反模式守卫"
if code_only watch/Shared/SharedContainer.swift | grep -q 'replaceItemAt'; then
  bad "SharedContainer 的代码里又出现 replaceItemAt —— 它要求目标已存在，会让快照永远写不进去"
else
  ok "SharedContainer 代码里没有 replaceItemAt"
fi

if code_only watch/Health/HealthAuthorizer.swift | grep -q 'authorizationStatus'; then
  bad "HealthAuthorizer 的代码里又用 authorizationStatus —— HealthKit 的读权限不可查询"
else
  ok "HealthAuthorizer 代码里没有 authorizationStatus"
fi

# 只检查「初次创建 ModelContainer 的那个 catch 分支」。
# recoverContainer 最末尾那个 fatalError 是**故意**的：
# 连内存库都建不起来说明 Schema 有硬错误，这时必须崩才能暴露问题。
INIT_FAIL_HAS_FATAL=$(awk '
  /container = try ModelContainer\(for: schema/ { start = NR }
  start && NR >= start && NR <= start + 8 { print }
' watch/App/WatchServices.swift | code_only | grep -c 'fatalError')
if [ "$INIT_FAIL_HAS_FATAL" -gt 0 ]; then
  bad "ModelContainer 初次创建失败的分支又用 fatalError —— 会导致每次冷启动必崩"
else
  ok "ModelContainer 初次失败走自愈路径，没有 fatalError"
fi

# ---------- 7. 密钥与产物不入库 ----------
section "7. 密钥与产物不入库"
if [ -f .gitignore ]; then
  for pat in '*.p8' '*.p12' '*.mobileprovision' 'log/'; do
    if grep -qF -- "$pat" .gitignore; then
      ok ".gitignore 覆盖 $pat"
    else
      bad ".gitignore 缺少 $pat"
    fi
  done
else
  bad "没有 .gitignore"
fi

# ---------- 8. workflow 里的 shell 代码块必须语法正确 ----------
# 为什么需要：workflow 的 run: 块本质是**字符串**，在 Windows 上编辑它没有任何反馈。
# 一个多余的 `{` 要等到 macOS runner 上才会炸（run #6 就是这么红的），
# 而且如果炸在"诊断步骤"里，还会把真正的失败原因一起吞掉。
section "8. workflow 的 shell 代码块语法"
TMPD=$(mktemp -d 2>/dev/null) || TMPD="/tmp/ci-verify-$$"
mkdir -p "$TMPD"

awk -v dir="$TMPD" '
  {
    ind = 0
    while (substr($0, ind + 1, 1) == " ") ind++
    if ($0 ~ /^[[:space:]]*run: *\|[[:space:]]*$/) { inblock = 1; n++; out = dir "/run-" n ".sh"; next }
    if (inblock) {
      if ($0 ~ /^[[:space:]]*$/ || ind >= 10) { print > out; next }
      inblock = 0
    }
  }
' .github/workflows/build.yml

NBLOCK=0
for f in "$TMPD"/run-*.sh; do
  [ -e "$f" ] || continue
  NBLOCK=$((NBLOCK + 1))
  # GitHub 的 ${{ ... }} 表达式是**运行前**由 Actions 替换掉的，bash 永远看不到它。
  # 但本地静态检查会看到，于是误报 "bad substitution"。先换成占位符再检查。
  sed 's/\${{[^}]*}}/GH_EXPR/g' "$f" > "$f.clean"
  if bash -n "$f.clean" 2> "$f.err"; then
    ok "run 块 #$NBLOCK 语法正确"
  else
    bad "run 块 #$NBLOCK 有 shell 语法错误："
    sed 's/^/         /' "$f.err"
  fi
done
[ "$NBLOCK" -eq 0 ] && bad "一个 run 块都没提取到（说明提取逻辑失效了，这一节等于没检查）"
rm -rf "$TMPD"

# ---------- 汇总 ----------
printf '\n== 汇总：%d 通过，%d 失败\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\033[31m结构性自检未通过\033[0m\n'
  exit 1
fi
printf '\033[32m结构性自检全部通过\033[0m\n'
