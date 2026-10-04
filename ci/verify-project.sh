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

# required-reason API 守卫：用了就必须在隐私清单里声明，否则 App Store Connect 直接拦。
# FileTimestamp 这一类最容易被顺手用上（读文件大小/时间就会碰到）。
#
# ⚠️ 必须先**逐文件去掉注释**再判断 —— 否则解释「为什么不能用它」的注释
#    自己就会命中（这个守卫第一版就是这么误报的）。`code_only` 一次只吃一个文件，
#    所以这里先把命中的文件列出来，再逐个过滤。
REQ_HIT=$(for f in $(grep -rl 'attributesOfItem' watch ios --include='*.swift' 2>/dev/null); do
            code_only "$f"
          done | grep -c 'attributesOfItem')
if [ "$REQ_HIT" -gt 0 ]; then
  bad "代码里用了 FileManager.attributesOfItem —— 那是 required-reason API（FileTimestamp 类别），必须在 PrivacyInfo.xcprivacy 里声明才能过审"
else
  ok "没有用 attributesOfItem（文件大小走 FileHandle.seekToEnd，不碰 required-reason API）"
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

# ci/ 下的独立脚本也要查 —— 它们不在 workflow 的 run 块里，上面那一步覆盖不到。
# （`ci/ship.sh` 就是一条命令走完整个发布流程的那个脚本，语法错会很致命）
for f in ci/*.sh; do
  [ -e "$f" ] || continue
  if bash -n "$f" 2> "$TMPD/syntax.err"; then
    ok "$f 语法正确"
  else
    bad "$f 有 shell 语法错误："
    sed 's/^/         /' "$TMPD/syntax.err"
  fi
done

rm -rf "$TMPD"

# ---------- 9. App 图标（缺了会被 App Store 上传直接拒收） ----------
# run #12 就是栽在这里：整个项目一个图标都没有，签名全过了、ipa 都传到
# App Store Connect 了，最后被服务端校验打回来：
#   Missing required icon file / Missing Info.plist value 'CFBundleIconName'
#   Missing Icons. No icons found for watch application ...
section "9. App 图标"
for cat in ios watch; do
  base="$cat/Assets.xcassets"
  for f in "$base/Contents.json" \
           "$base/AppIcon.appiconset/Contents.json" \
           "$base/AppIcon.appiconset/AppIcon-1024.png"; do
    if [ -f "$f" ]; then ok "$f"; else bad "缺少 $f"; fi
  done
done

# PNG 的 IHDR 里第 25 字节（0 起算）是 color type：
#   2 = truecolor（RGB，无 alpha）—— App Store 要求的就是这个
#   6 = truecolor + alpha        —— 会被拒收（"can't be transparent nor contain an alpha channel"）
for cat in ios watch; do
  png="$cat/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
  [ -f "$png" ] || continue
  ct=$(od -A n -t u1 -j 25 -N 1 "$png" 2>/dev/null | tr -d ' \n')
  case "$ct" in
    2) ok "$cat 图标是 RGB（无 alpha 通道）" ;;
    6) bad "$cat 图标是 RGBA —— 含 alpha 通道，App Store 会拒收" ;;
    *) bad "$cat 图标的 PNG color type 读不出来（得到 '${ct}'）" ;;
  esac
done

# 容忍冒号两边的空格：Xcode 写的是 `"platform" : "ios"`，但手写/脚本生成的可能是 `"platform": "ios"`
grep -qE '"platform" *: *"ios"' ios/Assets.xcassets/AppIcon.appiconset/Contents.json 2>/dev/null \
  && ok "iOS 图标的 platform 是 ios" \
  || bad "iOS 图标的 Contents.json 里 platform 不是 ios"
grep -qE '"platform" *: *"watchos"' watch/Assets.xcassets/AppIcon.appiconset/Contents.json 2>/dev/null \
  && ok "watchOS 图标的 platform 是 watchos" \
  || bad "watchOS 图标的 Contents.json 里 platform 不是 watchos"

# 两个 target 都必须显式指定 —— XcodeGen **不会**替你设这个（只有 Xcode 模板才会），
# 不设的话 actool 收不到 --app-icon，既不生成 CFBundleIconName 也不派生 120x120
NICON=$(grep -c 'ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon' project.yml)
if [ "$NICON" -ge 2 ]; then
  ok "ASSETCATALOG_COMPILER_APPICON_NAME 在 iOS 和 watch 两个 target 都设了"
else
  bad "ASSETCATALOG_COMPILER_APPICON_NAME 只出现 $NICON 次（应为 2）—— 图标不会进 bundle"
fi

# watch 的 asset catalog 必须显式接进 sources（iOS 的由 `- path: ios` 自动覆盖）
grep -q -- '- path: watch/Assets.xcassets' project.yml \
  && ok "watch/Assets.xcassets 已接进 watch target" \
  || bad "project.yml 没有引用 watch/Assets.xcassets"

# ---------- 10. 显示名 / watchOS 27 专属类型的取用方式 ----------
section "10. 显示名与 watchOS 27 类型"
NAME_COUNT=$(grep -c 'CFBundleDisplayName: 长明护心' project.yml)
if [ "$NAME_COUNT" -eq 3 ]; then
  ok "三个 target 的 CFBundleDisplayName 都是「长明护心」"
else
  bad "CFBundleDisplayName 为「长明护心」的 target 只有 $NAME_COUNT 个（应为 3：iOS / watch / widget）"
fi
if grep -q 'CFBundleDisplayName: 健康数据' project.yml; then
  bad "还有 target 用着旧显示名「健康数据」"
else
  ok "没有遗留的旧显示名"
fi

# 回归守卫（重要）：**不要**再用 `#if HAS_WATCHOS_27_SDK` 之类的 SDK 编译条件
# 去门控 watchOS 27 专属类型。那个条件依赖 CI runner 恰好装了新 SDK，
# 实测从未成立 —— 结果 RMSSD 长期「绿着但根本没编进产物」。
# 正确做法是用原始字符串构造标识符（老 SDK 能编译、新系统运行时可用）。
if code_only watch/Health/MetricCatalog.swift | grep -q 'HAS_WATCHOS_27_SDK'; then
  bad "MetricCatalog 又用 #if HAS_WATCHOS_27_SDK 门控了 —— CI 上该条件不成立，指标会静默消失"
else
  ok "MetricCatalog 没有用 SDK 编译条件门控 27 专属类型"
fi

if grep -q 'HKQuantityTypeIdentifierHeartRateVariabilityRMSSD' watch/Health/MetricCatalog.swift; then
  ok "RMSSD 用原始字符串标识符构造类型（老 SDK 也能编译）"
else
  bad "找不到 RMSSD 的原始字符串标识符"
fi

# 不能退回到引用 Swift 符号（那个符号在 watchOS 26 SDK 里不存在）
if code_only watch/Health/MetricCatalog.swift | grep -qE 'q\(\.heartRateVariabilityRMSSD\)'; then
  bad "又用 Swift 符号引用了 heartRateVariabilityRMSSD —— 在只有 26.x SDK 的 runner 上编译不过"
else
  ok "没有引用 watchOS 27 专属的 Swift 符号"
fi

# ---------- 汇总 ----------
printf '\n== 汇总：%d 通过，%d 失败\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\033[31m结构性自检未通过\033[0m\n'
  exit 1
fi
printf '\033[32m结构性自检全部通过\033[0m\n'
