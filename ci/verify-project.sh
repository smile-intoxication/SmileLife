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

# 「编译」步骤带 `continue-on-error: true`（为了让 job 走到最后统一汇总），
# 而 continue-on-error 会把那一步的失败**掩掉** —— 此后所有步骤看到的 `failure()`
# 都是 **false**。诊断步骤如果只写 `if: failure()`，**编译失败时 Issue 永远不会建**，
# 而"编译失败"恰恰是最需要远程诊断的情况（开发机是 Windows，看不到日志）。
# 实测踩到过：run #26 编译失败，仓库里没有新建任何 Issue，只能靠人下载 artifact。
N_DIAG=$(grep -c "if: failure() || steps.build.outcome == 'failure'" .github/workflows/build.yml 2>/dev/null)
if [ "$N_DIAG" -ge 2 ]; then
  ok "编译诊断步骤同时检查 failure() 与 steps.build.outcome（编译失败也会建 Issue）"
else
  bad "诊断步骤只检查了 failure()（只找到 $N_DIAG 处，应 ≥2）—— 编译步骤带 continue-on-error，它的失败被掩掉，Issue 永远不会建"
fi

# 证书清理那一步必须存在，而且必须带 `continue-on-error: true`。
#
# 为什么守：**它是维护动作，不是发布前提**。清理失败绝不能让发布失败 ——
# 否则"证书额度满了"这个本来可以放行的问题，会连带把整个发布堵死。
# 反过来，这一步不存在的话，每发布一次就烧掉一个证书额度，
# 攒够上限（实测 12 张）之后 Archive 会直接失败（v2.1 就是这么挂的）。
if [ -f ci/prune-dev-certs.py ]; then
  ok "证书清理脚本存在（ci/prune-dev-certs.py）"
else
  bad "缺少 ci/prune-dev-certs.py —— 没有它，每发布一次烧掉一个证书额度，攒满就再也签不了名"
fi

CERT_GUARD=$(awk '
  /清理旧的开发证书/ { inblock = 1; next }
  inblock && /^      - name:/ { inblock = 0 }
  inblock && /continue-on-error: true/ { print "yes"; exit }
' .github/workflows/build.yml 2>/dev/null)
if [ "$CERT_GUARD" = "yes" ]; then
  ok "证书清理步骤带 continue-on-error（维护动作不会堵死发布）"
else
  bad "证书清理步骤没有 continue-on-error: true —— 清理失败会连带让发布失败"
fi

if grep -q 'prune-dev-certs.py' .github/workflows/build.yml 2>/dev/null; then
  ok "workflow 已接入证书清理"
else
  bad "workflow 没有调用 ci/prune-dev-certs.py"
fi

echo
echo "== 16. 手表只搬运、不解释（数据通路的分层）"
# 这条边界值得机械守住，因为它**很容易在无意中被写回去**：
# 在手表上加一个"顺手算一下 RR / 求个中位数"看着无害，实际代价是
# **以后每加一个分析都要改手表代码、再走一轮 watchOS 发布**。
# 手表代码的迭代成本极高（用户得把 app 装到表上），手机随时能更新。
#
# 判据：手表侧**代码里**不出现 `RRPacking.pack`（那是"算完 RR 再打包"的标志）。
# 手表只该用 `BeatPacking` 搬原始时间戳。
#
# ⚠️ 必须先用 `code_only` 剥掉注释再查 —— 第一版直接 `grep -rn`，
#    结果被**解释这条规则的注释本身**触发了误报（注释里引用了 `RRPacking.pack`
#    这个符号名）。规则说明文字不该把规则自己判失败。
RR_IN_WATCH=""
for f in $(find watch -name '*.swift' 2>/dev/null); do
  if code_only "$f" | grep -q 'RRPacking\.pack'; then
    RR_IN_WATCH="$RR_IN_WATCH $(basename "$f")"
  fi
done
if [ -z "$RR_IN_WATCH" ]; then
  ok "手表侧不计算 RR 间期（只搬运原始时间戳）"
else
  bad "手表侧还在打包 RR 间期（RRPacking.pack）：$RR_IN_WATCH —— RR 必须在手机上算"
fi

# 反向：手机上必须真的在算 RR。
# 只查"手表没算"是不够的 —— 两边都不算的话图就是空的，而那是个**静默**的空。
if grep -q 'breakdown(fromOffsets' ios/Poincare.swift 2>/dev/null; then
  ok "手机侧由时间戳推导 RR 间期（按洞切段 + 相邻相减）"
else
  bad "手机侧没有推导 RR 间期 —— 手表不算是故意的，但手机必须算"
fi

# 时间戳载荷必须是 Optional：老版本手表发的是 rrPacked，没有这个字段。
# 写成非可选会让 Swift 合成的 Decodable 用 decode 而不是 decodeIfPresent，
# 老手表的整批数据会解码失败、**静默丢掉**。
if grep -q 'var beatOffsetsPacked: Data?' shared/RRSeries.swift 2>/dev/null; then
  ok "beatOffsetsPacked 是 Optional（兼容只发 rrPacked 的老手表）"
else
  bad "beatOffsetsPacked 必须是 Optional —— 老版本手表没有这个字段"
fi

# ---------- 16b. 「洞」标记（`precededByGap`）不许再被丢掉 ----------
#
# 这是一条**修过一次、绝不能再退回去**的边界：
# Apple 明确说 `precededByGap` 的意思是「这一拍前面有洞、可能漏了一拍或多拍」，
# 也就是"它和前一拍的时间差**不是**一个真实的心跳间隔"。
# 而我们的 RR 间期正是相邻相减算出来的 —— 丢掉这个标记的后果不是"少一个字段"，
# 而是**漏 1 拍把 800 ms 变成 1600 ms**，而 1600 ms 落在手机端
# 300–2000 ms 的生理范围内，于是它会伪装成一个真实间隔进散点图、并把 SDNN 拉大。
# 这个错误**不报错、不崩、图也画得出来**，属于最危险的那一类。
#
# 判据（四条都要）：
#   ① 查询只在一处 —— `HKHeartbeatSeriesQuery` 只允许出现在 HeartbeatReader.swift
#      （两处各写一份必然漂移；这也是"一个事实只允许一处定义"的既有原则）
#   ② 手表侧确实把标记带上了（同步引擎里出现 `precededByGap`）
#   ③ 载荷字段是 Optional（老版本兼容）
#   ④ 过滤逻辑真的在看那个标记（不是收下来又不用）
HB_QUERY_FILES=""
for f in $(find . -name '*.swift' -not -path './build/*' 2>/dev/null); do
  if code_only "$f" | grep -q 'HKHeartbeatSeriesQuery('; then
    HB_QUERY_FILES="$HB_QUERY_FILES $f"
  fi
done
if [ "$(echo $HB_QUERY_FILES | wc -w)" -eq 1 ] \
   && echo "$HB_QUERY_FILES" | grep -q 'watch/Health/HeartbeatReader.swift'; then
  ok "HKHeartbeatSeriesQuery 只有一处调用点（HeartbeatReader.swift）"
else
  bad "HKHeartbeatSeriesQuery 的调用点不是唯一一处：$HB_QUERY_FILES —— 洞标记会在别处被漏掉"
fi

if code_only watch/Health/HeartbeatReader.swift 2>/dev/null | grep -q 'precededByGap'; then
  ok "手表侧确实收下了 precededByGap（不再写成 _）"
else
  bad "HeartbeatReader 没有收 precededByGap —— 跨洞的差值会被当成真实 RR 间期"
fi

if grep -q 'var gapFlagsPacked: Data?' shared/RRSeries.swift 2>/dev/null; then
  ok "gapFlagsPacked 是 Optional（老手表没有这个字段）"
else
  bad "gapFlagsPacked 必须是 Optional —— 否则老手表发来的整批数据会解码失败"
fi

# ④ 收下来却不用 = 白做。判据用**代码**（`code_only` 剥注释），
#    免得被解释这条规则的注释自己触发（坑 #40 的误报）。
if code_only shared/RRSeries.swift | grep -q 'crossedGap'; then
  ok "跨洞的间隔确实被排除（breakdown 里检查了洞标记）"
else
  bad "breakdown 没有使用洞标记 —— 收下 precededByGap 却不用，跨洞间隔照样进图"
fi

# 两端的持久化字段也必须是 Optional：
# 给已有的 @Model 加**可选**属性是 SwiftData 的轻量迁移；
# 加非可选属性可能让 ModelContainer 打不开 —— 那是**每次启动都崩**，
# 而手机上的心跳序列是长期档案，不能拿来冒险。
if grep -q 'var gapsPacked: Data?' watch/Storage/Models.swift 2>/dev/null; then
  ok "HeartbeatSeriesRecord.gapsPacked 是 Optional（轻量迁移，不用改 schema）"
else
  bad "HeartbeatSeriesRecord.gapsPacked 必须是 Optional"
fi

if grep -q 'var gapsPacked: Data?' ios/PhoneModels.swift 2>/dev/null; then
  ok "PhoneHeartbeatSeries.gapsPacked 是 Optional（轻量迁移）"
else
  bad "PhoneHeartbeatSeries.gapsPacked 必须是 Optional"
fi

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

# ---------- 11. 跨设备共享代码的边界 ----------
# 仓库根有一个 `shared/`（手表 ↔ iPhone 共享），watch 下还有一个 `watch/Shared`
# （手表 app ↔ 小组件共享）。两者都只能依赖 Foundation，但**原因不同**：
#   · shared/      会被编进 iOS app —— 而 iOS app **刻意不申请健康权限**
#   · watch/Shared 会被编进小组件 —— 小组件**不该有 HealthKit 访问**
# 一旦有人在里面 import HealthKit，编译**照样通过**，但产品含义就变了
# （iOS app 被迫带上健康权限、小组件可能被系统判定为需要授权而白屏）。
section "11. 跨设备共享代码的边界"
NSHARED=$(grep -c -- '- path: shared' project.yml)
if [ "$NSHARED" -ge 2 ]; then
  ok "shared/ 已接进 iOS 与 watch 两个 target（$NSHARED 处）"
else
  bad "project.yml 只引用了 shared/ $NSHARED 次（应 ≥2：iOS + watch）。少接一个 target 会报 cannot find type in scope"
fi

for f in shared/MetricDisplay.swift shared/WatchWire.swift; do
  if [ -f "$f" ]; then ok "$f 存在"; else bad "缺少 $f"; fi
done

BANNED_RE='^[[:space:]]*import[[:space:]]+(HealthKit|SwiftData|WatchConnectivity|WidgetKit|SwiftUI)'
for f in shared/*.swift; do
  [ -e "$f" ] || continue
  if code_only "$f" | grep -qE "$BANNED_RE"; then
    bad "$f 引入了被禁止的框架（shared/ 会编进 iOS app 与 watch app，只能依赖 Foundation）"
  else
    ok "$f 只依赖 Foundation"
  fi
done

for f in watch/Shared/*.swift; do
  [ -e "$f" ] || continue
  if code_only "$f" | grep -qE "$BANNED_RE"; then
    bad "$f 引入了被禁止的框架（watch/Shared 会编进小组件，小组件不该碰 HealthKit）"
  else
    ok "$f 只依赖 Foundation"
  fi
done

# ⚠️ iOS app **刻意不引入 HealthKit**：它的数据全部来自手表传输。
#    直接读手机上的 HealthKit 是另一条路（数据也在，但包含 iPhone 自己产生的部分），
#    真要改成果条路，必须同时补 Info.plist 的用途说明与门户里的 HealthKit 能力，
#    不能只是随手 import 一下。
if grep -rqE '^[[:space:]]*import[[:space:]]+HealthKit' ios --include='*.swift'; then
  bad "ios/ 里出现了 import HealthKit —— iOS app 的数据应全部来自手表传输；要改直读必须先补 Info.plist 用途说明与 HealthKit 能力"
else
  ok "iOS app 没有引入 HealthKit（数据只来自手表传输）"
fi

# ---------- 12. 指标 id 在两边必须一致 ----------
# 线上只传 metricID（不传标题/单位）。所以 iPhone 必须自己有一份
# `metricID -> 展示信息` 的表。两边 id 集合不一致时：
#   · MetricDisplay 少一个 → 手机上是 `heart_rate` 这样的原始 id（难看但能看出来）
#   · MetricCatalog  少一个 → 手表永远不采集它（手机上永远空着，**完全看不出来**）
# 两种都不会编译报错，所以只能在这里守。
section "12. 指标 id 一致性（MetricCatalog ↔ MetricDisplay）"
DISPLAY_IDS=$(grep -oE 'id: "[A-Za-z0-9_]+"' shared/MetricDisplay.swift 2>/dev/null \
              | sed -e 's/id: "//' -e 's/"//' | sort -u)
CATALOG_IDS=$(grep -oE 'id: "[A-Za-z0-9_]+"' watch/Health/MetricCatalog.swift 2>/dev/null \
              | sed -e 's/id: "//' -e 's/"//' | sort -u)

printf '       MetricDisplay : %s\n' "$(printf '%s' "$DISPLAY_IDS" | tr '\n' ' ')"
printf '       MetricCatalog : %s\n' "$(printf '%s' "$CATALOG_IDS" | tr '\n' ' ')"

if [ -z "$DISPLAY_IDS" ] || [ -z "$CATALOG_IDS" ]; then
  bad "有一边的指标 id 一个都没提取到（提取逻辑失效了，这一节等于没检查）"
elif [ "$DISPLAY_IDS" = "$CATALOG_IDS" ]; then
  ok "两边 id 集合完全一致（$(printf '%s\n' "$DISPLAY_IDS" | grep -c .) 个指标）"
else
  bad "两边的指标 id 集合不一致："
  ONLY_DISPLAY=$(comm -23 <(printf '%s\n' "$DISPLAY_IDS") <(printf '%s\n' "$CATALOG_IDS") | tr '\n' ' ')
  ONLY_CATALOG=$(comm -13 <(printf '%s\n' "$DISPLAY_IDS") <(printf '%s\n' "$CATALOG_IDS") | tr '\n' ' ')
  printf '         只在 MetricDisplay 里（手表不会采集）：%s\n' "${ONLY_DISPLAY:-（无）}"
  printf '         只在 MetricCatalog 里（手机上没名字）：%s\n' "${ONLY_CATALOG:-（无）}"
fi

# 重复 id：MetricDisplay 的索引是循环覆盖的（刻意不 trap），
# 所以重复不会崩，只会"后者胜出"—— 同样必须在这里拦。
DUP=$(grep -oE 'id: "[A-Za-z0-9_]+"' shared/MetricDisplay.swift 2>/dev/null \
      | sed -e 's/id: "//' -e 's/"//' | sort | uniq -d | tr '\n' ' ')
if [ -n "$DUP" ]; then
  bad "MetricDisplay 里有重复的指标 id：$DUP"
else
  ok "MetricDisplay 里没有重复 id"
fi

# 每个指标都必须**显式**声明图表形态。
#
# 为什么守这一条：`MetricDisplay.chartStyles` 有 `?? .line` 兜底，
# 所以漏掉一个指标**不会报错**，只会让那个体征悄悄退回折线图 ——
# 而"某个图又变回折线了"没有任何线索指向"配置漏了一行"。
#
# 判据：id 以**字典键**的形式出现（`"id": .xxx`）。
# ⚠️ 不要只数 `"id"` 出现的次数 —— 像 `sleep_analysis` 在 `categoryLabel`
#    里也出现过一次，那样计数会虚高、把漏配掩盖掉（这个守卫第一版就是这么写的）。
# ⚠️ 也要先去掉注释，否则解释文字里的 id 会让计数虚高。
NO_STYLE=$(for id in $(grep -oE 'id: "[A-Za-z0-9_]+"' shared/MetricDisplay.swift 2>/dev/null \
                       | sed -e 's/id: "//' -e 's/"//' | sort -u); do
             n=$(code_only shared/MetricDisplay.swift | grep -c "\"$id\":")
             [ "$n" -lt 1 ] && printf '%s ' "$id"
           done)
if [ -z "$NO_STYLE" ]; then
  ok "每个指标都显式声明了图表形态（没有落到折线兜底）"
else
  bad "这些指标没在 MetricDisplay.chartStyles 里声明图表形态（会静默退回折线图）：$NO_STYLE"
fi

# 反向：`chartStyles` 里不许有 `all` 里不存在的 id（改指标 id 时容易漏删）
STRAY=$(grep -oE '^        "[A-Za-z0-9_]+":' shared/MetricDisplay.swift 2>/dev/null \
        | sed -e 's/^ *"//' -e 's/":$//' | sort -u \
        | while read -r id; do
            grep -q "id: \"$id\"" shared/MetricDisplay.swift || printf '%s ' "$id"
          done)
if [ -z "$STRAY" ]; then
  ok "chartStyles 里没有多余（已不存在的）指标 id"
else
  bad "chartStyles 里有 all 中不存在的指标 id：$STRAY"
fi

# ---------- 13. WatchConnectivity 接线 ----------
# 「手机上一直没数据」有五六种原因，而它们**在界面上长得一模一样**。
# 下面这些断言守的是其中最隐蔽的几类 —— 编译全过、运行也不崩，就是没数据。
section "13. WatchConnectivity 接线"
for f in watch/Upload/WatchLinkSession.swift watch/Upload/OutboxFlusher.swift shared/WatchWire.swift \
         ios/WatchLink.swift ios/PhoneStore.swift ios/PhoneModels.swift; do
  if [ -f "$f" ]; then ok "$f 存在"; else bad "缺少 $f"; fi
done

# 大批量数据必须走 transferUserInfo（不需要对端可达），**不能**用 sendMessage
# （它要求 isReachable，而 iPhone 在后台几乎永远不可达 → 每次同步都白跑）。
if code_only watch/Upload/WatchLinkSession.swift | grep -q 'transferUserInfo'; then
  ok "手表端用 transferUserInfo 投递（不需要对端可达）"
else
  bad "手表端没有用 transferUserInfo —— sendMessage 要求对端可达，后台同步会大面积失败"
fi
# ⚠️ 必须先**逐文件去掉注释**再判断 —— 解释"为什么不能用 sendMessage"的
#    注释自己就会命中（和 attributesOfItem 那个守卫是同一个坑）。
SENDMSG_HIT=$(for f in $(grep -rl 'sendMessage' watch ios shared --include='*.swift' 2>/dev/null); do
                code_only "$f"
              done | grep -c 'sendMessage')
if [ "$SENDMSG_HIT" -gt 0 ]; then
  bad "代码里出现了 sendMessage —— 它要求对端可达，而手表后台时 iPhone 几乎永远不可达，会静默丢数据"
else
  ok "没有用 sendMessage 做批量传输（只用 transferUserInfo）"
fi

# 两端都必须在**启动早期**激活会话。晚了会静默失败：
# 手表在后台把数据传过来时，手机上的 app 可能从没被打开过，
# 那种情况下任何 SwiftUI 视图都不会被创建 —— 在视图的 .task 里激活正好错过。
if grep -q 'WatchServices.shared.startLink()' watch/App/AppleWatchHealthApp.swift 2>/dev/null; then
  ok "手表在 applicationDidFinishLaunching 里激活会话"
else
  bad "手表没有在启动早期调用 WatchServices.shared.startLink()"
fi
if grep -q 'PhoneServices.shared.startLink()' ios/AppleWatchHealthIOSApp.swift 2>/dev/null; then
  ok "iPhone 在 didFinishLaunchingWithOptions 里激活会话"
else
  bad "iPhone 没有在启动早期调用 PhoneServices.shared.startLink()（只放在视图里会错过后台投递）"
fi
if grep -q 'didFinishLaunchingWithOptions' ios/AppleWatchHealthIOSApp.swift 2>/dev/null; then
  ok "iPhone 用了 UIApplicationDelegateAdaptor（SwiftUI App 没有 didFinishLaunching）"
else
  bad "iPhone 没有 UIApplicationDelegateAdaptor —— SwiftUI 的 App 里拿不到 didFinishLaunching"
fi

# 换手表（配对切换）时必须重新 activate，否则新表的数据**永远收不到**，
# 而界面上一切正常（旧的会话说自己还是 activated）。
if code_only ios/WatchLink.swift | grep -q 'sessionDidDeactivate'; then
  if code_only ios/WatchLink.swift | sed -n '/sessionDidDeactivate/,/^    }/p' | grep -q 'activate()'; then
    ok "sessionDidDeactivate 里重新激活了会话（换手表后还能收到数据）"
  else
    bad "sessionDidDeactivate 里没有重新 activate() —— 用户换手表后新表数据永远收不到"
  fi
else
  bad "ios/WatchLink.swift 没有实现 sessionDidDeactivate"
fi

# 幂等去重是「至少一次投递」能成立的前提：手表可能重发，手机必须天然幂等。
# 去掉 .unique 不会编译报错，但表现是"重发一次就多一条重复数据"。
if grep -q '@Attribute(.unique) var uuid: UUID' ios/PhoneModels.swift 2>/dev/null; then
  ok "PhoneSample 的 uuid 是唯一键（重复投递会变成更新而不是插入）"
else
  bad "PhoneSample 的 uuid 不是 @Attribute(.unique) —— 重发会产生重复数据"
fi
if grep -q '@Attribute(.unique) var key: String' ios/PhoneModels.swift 2>/dev/null; then
  ok "PhoneRollup 的合成键是唯一键"
else
  bad "PhoneRollup 的 key 不是 @Attribute(.unique) —— 同一时间桶会出现多行"
fi

# 索引去掉不会编译报错，只会让"切时间范围"退化成全表扫描。
# 手机上是几十万行，差别是"秒开"和"卡住"。
if grep -q '#Index<PhoneSample>' ios/PhoneModels.swift 2>/dev/null; then
  ok "PhoneSample 声明了 #Index（图表按时间段查询全靠它）"
else
  bad "PhoneSample 没有 #Index —— 图表的按时间段查询会全表扫描"
fi

# 协议版本必须先检查再解码：手表比手机新时应当**明确报错**，
# 而不是把解不出来的负载当成"一批空数据"（那会表现成"就是没数据"）。
if code_only ios/WatchLink.swift | grep -q 'currentVersion'; then
  ok "iPhone 端先校验协议版本再解码"
else
  bad "iPhone 端没有校验 SampleBatch.currentVersion —— 版本不匹配时会静默丢数据"
fi

# 线协议"**只增不改**"的机械保证：`SampleBatch` 的新字段必须是 `Optional`。
#
# ⚠️ Swift 合成的 `Decodable` 对**非可选**属性用 `decode` 而不是 `decodeIfPresent`
# —— 也就是说 `var x: [T] = []` 这种"带默认值"的写法**不能**容忍缺失的键。
# 手表比手机新时，老手机一解码就抛错、**整批数据丢掉**（而不是忽略新字段）。
PROTO_OPT=$(code_only shared/WatchWire.swift | grep -cE 'var heartbeatSeries: \[HeartbeatSeriesPayload\]\?')
if [ "$PROTO_OPT" -ge 1 ]; then
  ok "SampleBatch.heartbeatSeries 是 Optional（老版本解码器能安全忽略）"
else
  bad "SampleBatch.heartbeatSeries 不是 Optional —— 老版本解码会失败、整批数据丢掉"
fi

# ---------- 14. WCSession 属性的平台不对称 ----------
# WCSession 的属性在 iOS 与 watchOS 上**不是同一套**，用错方向只会在
# "编译另一个平台"时报错 —— 对于一个只属于某个 target 的文件来说，
# 那就是它**第一次被编译**的时候（手表端那个文件也是这么炸的）。
# 这类错误靠类型系统在 Windows 上抓不到，但能抓名字。
#
#   · `isPaired` / `isWatchAppInstalled`  → **iOS 专属**（头文件标了 __WATCHOS_UNAVAILABLE）
#   · `isCompanionAppInstalled`           → **watchOS 专属**（__IOS_UNAVAILABLE）
#
# 实测踩到过：手表端写了一行 `session?.isPaired`，CI 报
#   `error: 'isPaired' is unavailable in watchOS`（Issue #5）。
section "14. WCSession 属性的平台不对称"
# ⚠️ 判据必须写成「**成员访问**」形式（名字前面带一个点），不能只查裸名字。
#    实测踩到一次**纯误报**：给 `HeartbeatReader.Beats` 加了一个
#    `var isPaired: Bool`（本意是"两个数组长度对齐"），这一节就报警说
#    "手表端用了 iOS 专属属性" —— 纯粹是名字撞车。
#    而真正的违规形态一定是**访问属性**：`session?.isPaired` / `session.isPaired`
#    （Issue #5 那次就是 `session?.isPaired`）。
#    收紧判据不是纵容，而是让守卫只在真出问题时报警 ——
#    守卫一旦误报，久而久之就没人信它了（脚本开头那句注释说的正是这件事）。
IOS_ONLY_HIT=$(for f in $(grep -rl -E '\.(isPaired|isWatchAppInstalled)' watch --include='*.swift' 2>/dev/null); do
                 code_only "$f"
               done | grep -c -E '\.(isPaired|isWatchAppInstalled)')
if [ "$IOS_ONLY_HIT" -gt 0 ]; then
  bad "watch/ 里用了 WCSession 的 iOS 专属属性（isPaired / isWatchAppInstalled）—— watchOS 上是 __WATCHOS_UNAVAILABLE，编译不过"
else
  ok "watch/ 没有用 WCSession 的 iOS 专属属性"
fi

WATCH_ONLY_HIT=$(for f in $(grep -rl 'isCompanionAppInstalled' ios --include='*.swift' 2>/dev/null); do
                   code_only "$f"
                 done | grep -c 'isCompanionAppInstalled')
if [ "$WATCH_ONLY_HIT" -gt 0 ]; then
  bad "ios/ 里用了 isCompanionAppInstalled —— 它是 watchOS 专属（__IOS_UNAVAILABLE），iOS 上编译不过"
else
  ok "ios/ 没有用 watchOS 专属的 WCSession 属性"
fi

# ---------- 15. 探针查询的类型必须在读授权集合里 ----------
# 通用问题：HealthKit 对**没授权的类型返回空数组、不返回错误**，
# 所以"探针报 0 条"和"这台设备真的没这个数据"在界面上**长得一模一样**。
# 只要探针查的类型漏在 readTypes 之外，这个探针的输出就完全不可信 —— 而且看不出来。
#
# 实测踩到过：心跳序列是 `HKSeriesType`（**不是** `HKQuantityType`），
# 所以它进不了 `MetricCatalog.all` 那张指标表，也就没被加进 `readTypes`。
# v1.7 的诊断界面因此报「近 7 天 0 条序列」，
# 差点据此写下「房颤历史关闭时手表不写逐拍数据」的结论 —— 而那个 0 毫无意义。
section "15. 探针查询的类型必须在读授权集合里"
if grep -q 'HKSeriesType.heartbeat()' watch/Health/MetricCatalog.swift 2>/dev/null; then
  ok "心跳序列类型在 MetricCatalog（读授权集合）里声明"
else
  bad "MetricCatalog 里没有 HKSeriesType.heartbeat() —— 心跳序列不在读授权集合里，探针报的「0 条」不可信"
fi

# 同一个类型不能在探针里就地构造：那会出现「申请的是 A、查的是 B」，
# 而查询只返回空数组，表现成"设备没数据"。
PROBE_INLINE=$(code_only watch/Health/HealthProbe.swift | grep -c 'HKSeriesType.heartbeat()')
if [ "$PROBE_INLINE" -eq 0 ]; then
  ok "探针没有就地构造心跳序列类型"
else
  bad "HealthProbe.swift 里就地写了 HKSeriesType.heartbeat() —— 必须改用 MetricCatalog.heartbeatSeriesType，否则两处可能不一致"
fi
if code_only watch/Health/HealthProbe.swift | grep -q 'MetricCatalog.heartbeatSeriesType'; then
  ok "探针用的是 MetricCatalog.heartbeatSeriesType（单一来源）"
else
  bad "HealthProbe.swift 没有引用 MetricCatalog.heartbeatSeriesType"
fi

# 授权未决时**不能推进同步游标**。
#
# HealthKit 对**没授权的类型返回空数组 + 一个有效的新 `HKQueryAnchor`**。
# 于是有一条极隐蔽的路径：后台刷新在用户点授权之前先跑一轮 → 每类都"成功"
# 返回 0 条 + 新游标 → 游标被推进 → 用户之后授权成功，
# 从那个游标往后查**只会拿到新数据**，授权前那段历史**永远补不回来，零报错**。
#
# 机械保证：同步引擎里必须有 `canAdvanceAnchor` 参与游标落盘，
# 且授权状态来自 `HealthAuthorizer.isAuthorizationPending()`（与弹窗判断同一处逻辑）。
if code_only watch/Health/HealthSyncEngine.swift | grep -q 'canAdvanceAnchor' \
   && grep -q 'isAuthorizationPending' watch/Health/HealthAuthorizer.swift; then
  ok "同步游标受授权状态保护（未授权时不落盘，避免永久丢掉授权前的历史）"
else
  bad "同步引擎没有用 canAdvanceAnchor 保护游标落盘 —— 未授权时推进游标会永久丢历史且零报错"
fi

echo
echo "== 17. HRV：指标注册表与门槛的一致性"
# HRV 的指标定义在 `HRVMetrics.all`，取值在 `HRVResult.value(for:)` 的 switch 里。
# 两处漏一个的后果**不同、但都静默**：
#   · 表里有、switch 里没有 → 界面上那一行永远是「—」，看起来像"没有数据"
#   · switch 里有、表里没有 → 那个值算出来了却**永远不显示**（白算）
# 所以必须**双向**一致。
#
# ⚠️ **字符类必须含数字**（`[a-z0-9_]+`）。第一版写的是 `[a-z_]+`，于是
# `sd1` `sd2` `pnn20` `pnn50` **四个指标被静默漏掉** —— 而两个集合被同一个正则
# 同时截断，所以守卫照样报"双向一致"，**是一次假通过**。
# 一个会悄悄漏掉部分输入的守卫，比没有守卫更糟。
HRV_REG=$(grep -oE 'id: "[a-z0-9_]+"' ios/HRVAnalysis.swift 2>/dev/null | sed 's/id: "//;s/"//' | sort -u)
HRV_SWITCH=$(code_only ios/HRVAnalysis.swift | grep -oE 'case "[a-z0-9_]+":' | sed 's/case "//;s/"://' | sort -u)
if [ -z "$HRV_REG" ] || [ -z "$HRV_SWITCH" ]; then
  bad "没能从 ios/HRVAnalysis.swift 提取 HRV 指标表或取值 switch（结构变了？）"
else
  # —— 元守卫：提取到的条数必须等于**声明处**的条数 ——
  # 否则就是"提取正则漏了"，而不是"表漏了"。这两种情况的修法完全不同，
  # 而且前者会让下面的一致性检查**永远通过**。
  HRV_DECLARED=$(grep -c 'HRVMetric(id:' ios/HRVAnalysis.swift)
  HRV_FOUND=$(printf '%s\n' "$HRV_REG" | wc -l | tr -d ' ')
  if [ "$HRV_DECLARED" != "$HRV_FOUND" ]; then
    bad "提取到 $HRV_FOUND 个指标 id，但文件里有 $HRV_DECLARED 个 HRVMetric —— **提取正则漏了**，一致性检查不可信"
  else
    ok "指标 id 提取完整（$HRV_FOUND 个，与声明数一致）"
  fi
  ONLY_REG=$(comm -23 <(printf '%s\n' "$HRV_REG") <(printf '%s\n' "$HRV_SWITCH") | tr '\n' ' ')
  ONLY_SW=$(comm -13 <(printf '%s\n' "$HRV_REG") <(printf '%s\n' "$HRV_SWITCH") | tr '\n' ' ')
  if [ -z "$ONLY_REG" ] && [ -z "$ONLY_SW" ]; then
    ok "HRV 指标表与取值 switch 双向一致（$HRV_FOUND 个指标）"
  else
    [ -n "$ONLY_REG" ] && bad "HRVMetrics 里有、取值 switch 里没有（会永远显示「—」）：$ONLY_REG"
    [ -n "$ONLY_SW" ] && bad "取值 switch 里有、HRVMetrics 里没有（算出来却永远不显示）：$ONLY_SW"
  fi
fi

# 门槛**必须真的被界面用到** —— 否则"不给不成立的数字"就只是注释里的愿望。
# 这条守的是一个很容易发生的退化：有人把 partition 换成"全列出来"，
# 于是一段 40 秒的序列又开始显示 VLF 和 LF/HF，而且没有任何报错。
if grep -q 'HRVMetrics\.partition' ios/HRVCards.swift 2>/dev/null; then
  ok "界面按门槛过滤（HRVMetrics.partition）—— 不成立的指标不会显示数值"
else
  bad "HRVCards 没有调用 HRVMetrics.partition —— 门槛成了摆设，短序列会照出频域数字"
fi

# 卡片得真的接进图表页，否则整块是死代码
if grep -q 'HeartbeatHRVCard()' ios/ChartView.swift 2>/dev/null; then
  ok "HRV 卡片已接进图表页"
else
  bad "HeartbeatHRVCard 没有出现在 ChartView 里 —— 写了但没人用"
fi

# —— 「交感 / 副交感」必须用**归一化值（nU）**，不能用绝对功率（ms²）——
# 需求方指出过一次，而且我一开始确实写错了。绝对功率受总功率、呼吸深度、体位影响，
# **两个 ms² 的数直接比高度 = 在比两个不同量纲的数谁大**。
# 参考报告那张图的表里写的本来就是 `LF Norm 65.403 nU` / `HF Norm 34.597 nU`；
# 归一化后两者**加起来恒为 100**，两根柱子表示的才是"平衡"。
# 判据用**参数标签**（lfNorm:/hfNorm: vs lfPower:/hfPower:）—— 精确且不会误伤文案。
if grep -qE 'LFHFBarChart\((lf|hf)Norm:' ios/HRVCards.swift 2>/dev/null; then
  ok "交感/副交感柱状图用的是归一化值（nU）"
else
  bad "交感/副交感柱状图没用归一化值 —— 绝对功率（ms²）不能当交感/副交感之比看"
fi
if grep -qE 'LFHFBarChart\((lf|hf)Power:' ios/HRVCards.swift 2>/dev/null; then
  bad "交感/副交感柱状图传了绝对功率（ms²）—— 必须用归一化值 nU"
fi

# —— 直方图的条数轴必须是**固定上限** ——
# 需求方指定固定 20。自适应纵轴会让"50 拍的一条序列"和"300 拍的一条序列"
# 看起来一样高，而这张图的用途正是跨序列比较分布形状。
if grep -q 'chartYScale(domain: 0\.\.\.countLimit)' ios/HRVCards.swift 2>/dev/null; then
  ok "直方图条数轴是固定上限（跨序列可比）"
else
  bad "直方图条数轴没有固定上限 —— 自适应会让不同拍数的序列看起来一样高"
fi
# —— 视图层不许做生理单位换算 ——
# 需求方明确纠正过一次：波形图要画**心跳序列本身（RR 间期 ms）**，
# 而不是它的换算结果（瞬时心率 BPM = 60000 ÷ RR）。
# 这不只是"哪个更标准"：BPM 会把**数据源**讲错 ——
#   · `HKHeartbeatSeriesSample`（逐拍时间戳 → RR）
#   · `HKQuantityTypeIdentifierHeartRate`（心率样本）
# 是**两套不同的数据**。约束：换算只在分析层做一次，界面只画分析层给的值。
#
# ⚠️ **判据要打在"违规的形态"上，不是"符号"上** —— 这里踩了两次：
# · 第一版直接 `grep 60_?000`，被**解释这条规则的注释**触发（坑 #40 的误报，又犯一次）；
# · 光加 `code_only`（剥 `//`）**也不够** —— 界面文案里那句
#   「BPM = 60000 ÷ RR」是**字符串字面量**，剥注释剥不掉，
#   而且**说明文字本来就必须提到那个符号**才能讲清楚。
# ✅ 所以判据改成"**做了一次心率换算**"这个动作本身：`60000 / …`（一个除法）。
#   解释性文字用的是 `÷`，不会命中 —— 这才是"形态"和"符号"的区别。
if code_only ios/HRVCards.swift | grep -qE '60_?000(\.0)?[[:space:]]*/'; then
  bad "HRVCards 里做了心率换算（60000 / RR）—— 视图层不该做单位换算，纵轴要画 RR 间期(ms)"
else
  ok "波形图纵轴画的是 RR 间期(ms)，视图层没有做心率换算"
fi
# —— 结构体里声明为 `let` 的字段，不许在**构造之后**再赋值 ——
# 实测踩到（run #52）：`HRVResult.frequencyResolution` 写成 `let`，
# 却在 `analyze()` 里 `result.frequencyResolution = ...`，CI 报
#   error: cannot assign to property: 'frequencyResolution' is a 'let' constant
# 这类错误**本机完全看不出来**（没有 Swift 编译器），而且和业务逻辑无关、
# 纯粹是"声明与用法不一致"——所以最适合用机械检查挡在推送之前。
HRV_LET=$(code_only ios/HRVAnalysis.swift | awk '/^struct HRVResult/,/^}/' \
          | grep -oE '^    let [a-zA-Z]+' | awk '{print $2}')
if [ -z "$HRV_LET" ]; then
  bad "没能从 HRVResult 提取到 let 字段（结构变了？）"
else
  HRV_LET_BAD=""
  for field in $HRV_LET; do
    if code_only ios/HRVAnalysis.swift | grep -qE "result\.$field *="; then
      HRV_LET_BAD="$HRV_LET_BAD $field"
    fi
  done
  if [ -z "$HRV_LET_BAD" ]; then
    ok "HRVResult 的 let 字段没有被构造后赋值（$(printf '%s\n' "$HRV_LET" | wc -l | tr -d ' ') 个）"
  else
    bad "HRVResult 里这些字段是 let 却在构造后被赋值（CI 会报 cannot assign to property）：$HRV_LET_BAD"
  fi
fi
# 频域算法是**本地验证过**的（手写 FFT 与朴素 DFT 对照、频带功率对已知信号），
# 验证脚本不能丢 —— 丢了就没人能复核"频带积分有没有少乘 Δf"这类不出声的错误。
if ls ci/hrv_check*.py >/dev/null 2>&1; then
  ok "HRV 算法的本地验证脚本还在（ci/hrv_check*.py）"
else
  bad "缺少 ci/hrv_check*.py —— 频域算法的可复核证据丢了"
fi
echo
echo "== 18. 默认时间范围：由采样密度决定（漏了不会报错，只会画成一坨）"
# 心率全天每 5 秒一条（最坏约 17,000 条/天），7 天就是十几万个点 —— 画出来是一坨。
# 而**漏掉一个高频指标不会报错**，只会让它按 7 天画，所以这里机械守一下。
if grep -q 'static func `default`(forMetricID' ios/ChartView.swift 2>/dev/null; then
  ok "存在「按体征取默认范围」的单一来源（ChartRange.default(forMetricID:)）"
else
  bad "找不到 ChartRange.default(forMetricID:) —— 默认范围没有单一来源"
fi
MISSING_RANGE=""
for high_freq in heart_rate resting_heart_rate walking_heart_rate_average; do
  # 必须出现在 default(forMetricID:) 那个 switch 的 case 列表里
  if ! awk '/static func `default`\(forMetricID/,/^    }/' ios/ChartView.swift \
       | grep -q "\"$high_freq\""; then
    MISSING_RANGE="$MISSING_RANGE $high_freq"
  fi
done
if [ -z "$MISSING_RANGE" ]; then
  ok "高频心率类指标都在默认范围表里（1 天）"
else
  bad "这些高频指标没进默认范围表（会按 7 天画成一坨）：$MISSING_RANGE"
fi

# 「自动」这一档必须真的被界面用上 —— 否则"按体征取默认"只是摆设
if grep -q 'effectiveRange(for:' ios/ChartView.swift 2>/dev/null; then
  ok "图表页确实按体征取有效范围（effectiveRange(for:)）"
else
  bad "ChartView 没有调用 effectiveRange(for:) —— 默认范围没被用上"
fi

# 河流图的三条语义要求
# 🔴 **逐条序列，不许按小时平均** —— 需求方明确否掉过第一版的"按小时取均值"：
# 均值会把"这一小时有 5 条"和"只有 1 条"抹平成同一个数，
# 而这两件事的可信度差得很远（实测：单条散布 22%、平均 5 条 10%）。
if awk '/func hrvNormTrend/,/^    }/' ios/PhoneStore.swift | grep -q 'of: \.hour'; then
  bad "hrvNormTrend 里出现了按小时聚合 —— 河流图必须逐条序列画，不许取平均"
else
  ok "河流图是逐条序列（没有按小时平均）"
fi
# 河流图要用 AreaMark（平滑带状），不是一堆柱子
if grep -q 'AreaMark' ios/HRVCards.swift 2>/dev/null; then
  ok "河流图用的是 AreaMark（带状），不是柱状"
else
  bad "河流图没有用 AreaMark —— 河流图要的是连续带状，不是柱子"
fi
# 跳过的序列数必须能回报到界面（不然"记录太短"会被读成"那段时间没戴表"）
if grep -q 'skippedShort' ios/HRVCards.swift 2>/dev/null; then
  ok "界面会如实说明有多少条序列因太短没画进去"
else
  bad "界面没有回报 skippedShort —— 「记录太短」会被误读成「没有记录」"
fi
if grep -q 'hrvNormTrend' ios/PhoneStore.swift 2>/dev/null; then
  ok "河流图的数据来自逐条序列（PhoneStore.hrvNormTrend）"
else
  bad "缺少 PhoneStore.hrvNormTrend —— 河流图没有数据来源"
fi
if grep -q 'chartYScale(domain: 0\.\.\.100)' ios/HRVCards.swift 2>/dev/null; then
  ok "河流图的纵轴固定 0–100 nU（归一化值两者恒和为 100）"
else
  bad "河流图纵轴没有固定 0–100 —— 归一化值的和恒为 100，必须固定"
fi
# ---------- 汇总 ----------
printf '\n== 汇总：%d 通过，%d 失败\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\033[31m结构性自检未通过\033[0m\n'
  exit 1
fi
printf '\033[32m结构性自检全部通过\033[0m\n'
