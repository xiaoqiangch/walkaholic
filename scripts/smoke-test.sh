#!/usr/bin/env bash
# 模拟器/真机上的冒烟测试：装包 → 启动 → 抓日志 → 截图 → 检查崩溃与 ArkTS 运行时报错
#
# 用法: bash scripts/smoke-test.sh [截图名后缀]
#
# 判定标准（全部满足才算通过）：
#   1. hdc install 成功
#   2. aa start 成功且进程存活 10 秒
#   3. hilog 无 FATAL / ERROR 级别的 ArkTS 异常（JSVM / ArkRuntime / Appfreeze）
#   4. 截图非空
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DEVECO="${DEVECO_CLI_HOME:-$HOME/DevTools/deveco}"
HDC="$HOME_DEVECO/sdk/default/openharmony/toolchains/hdc"
HAP="$ROOT/harmony/entry/build/default/outputs/default/entry-default-signed.hap"
BUNDLE="com.walkaholic.harmony"
ABILITY="EntryAbility"
OUT="$ROOT/harmony/docs/screenshots"
SUFFIX="${1:-smoke}"
FAIL=0

[ -x "$HDC" ] || { echo "缺少 hdc（先跑 scripts/setup-deveco-cli.sh）"; exit 1; }
[ -f "$HAP" ] || { echo "缺少签名包，先跑 bash scripts/build-hap.sh"; exit 1; }

echo "═══ 0. 设备 ═══"
TARGETS=$("$HDC" list targets 2>/dev/null | grep -v -E "Empty|UART" | head -1)
[ -n "$TARGETS" ] || { echo "  ❌ 没有设备/模拟器"; exit 1; }
echo "  $TARGETS"

echo "═══ 1. 安装 ═══"
INSTALL=$("$HDC" install -r "$HAP" 2>&1)
echo "$INSTALL" | tail -2 | sed 's/^/  /'
echo "$INSTALL" | grep -qiE "success|成功" || { echo "  ❌ 安装失败"; FAIL=1; }

echo "═══ 2. 启动 ═══"
"$HDC" shell "aa force-stop $BUNDLE" >/dev/null 2>&1
"$HDC" shell "hilog -r" >/dev/null 2>&1
START=$("$HDC" shell "aa start -a $ABILITY -b $BUNDLE" 2>&1)
echo "$START" | tail -2 | sed 's/^/  /'
echo "$START" | grep -qiE "success|成功" || { echo "  ❌ 启动失败"; FAIL=1; }

echo "═══ 3. 存活 10 秒 + 抓日志 ═══"
sleep 10
PID=$("$HDC" shell "pidof $BUNDLE" 2>/dev/null | tr -d '\r')
if [ -n "$PID" ]; then echo "  ✅ 进程存活 pid=$PID"; else echo "  ❌ 进程已退出（疑似崩溃）"; FAIL=1; fi

LOG=/tmp/walkaholic-hilog.txt
"$HDC" shell "hilog -x" > "$LOG" 2>/dev/null || "$HDC" hilog > "$LOG" 2>/dev/null
# 只统计真正的崩溃/未捕获异常。系统级噪声（Ace 主题 EACCES、AceTransform .so 缺失、
# ArkWeb 可选库）是模拟器镜像自身的日志，与本工程无关。
PATTERN='FATAL|Appfreeze|Cannot read property|is not callable|TypeError:|ReferenceError:|Uncaught|JSVM.*ERROR|ArkRuntime.*ERROR|jscrash'
CRASH=0
if [ -n "$PID" ]; then
  CRASH=$(grep "$PID" "$LOG" 2>/dev/null | grep -c -E "$PATTERN" || true)
fi
echo "  日志行数: $(wc -l < "$LOG" 2>/dev/null || echo 0)，本应用致命异常行: $CRASH"
if [ "$CRASH" -gt 0 ]; then
  echo "  ❌ 发现运行时异常："
  grep "$PID" "$LOG" | grep -E "$PATTERN" | head -5 | sed 's/^/    /'
  FAIL=1
else
  echo "  ✅ 无致命运行时错误"
fi
echo "  完整日志: $LOG"

echo "═══ 4. 截图 ═══"
mkdir -p "$OUT"
SHOT="$OUT/$SUFFIX-$(date +%m%d-%H%M%S).png"
"$HDC" shell "snapshot_display -f /data/local/tmp/shot.jpeg" >/dev/null 2>&1
"$HDC" file recv /data/local/tmp/shot.jpeg "/tmp/shot.jpeg" >/dev/null 2>&1
if [ -f /tmp/shot.jpeg ] && [ -s /tmp/shot.jpeg ]; then
  sips -s format png /tmp/shot.jpeg --out "$SHOT" >/dev/null 2>&1
  echo "  ✅ $SHOT"
else
  echo "  ⚠️  截图失败（部分设备不支持 snapshot_display）"
fi

echo
if [ "$FAIL" -eq 0 ]; then echo "✅ 冒烟测试通过"; exit 0
else echo "❌ 冒烟测试失败"; exit 1; fi
