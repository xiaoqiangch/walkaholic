#!/bin/sh
# Walkaholic 鸿蒙版 一键构建 + 安装 + 启动
# 用法: ./build-install.sh
#
# 依赖 DevEco Studio 工具链 + 已在 IDE 里配置好的签名

set -e

PROJ="$(cd "$(dirname "$0")" && pwd)"
IDE=/Volumes/XQProjects/DevTools/apps/DevEco-Studio.app/Contents

[ -d "$IDE" ] || { echo "IDE 未找到: $IDE"; exit 1; }

HDC="$IDE/sdk/default/openharmony/toolchains/hdc"
NODE="$IDE/tools/node/bin/node"
HVIGOR="$IDE/tools/hvigor/bin/hvigorw.js"

export DEVECO_SDK_HOME="$IDE/sdk"
export JAVA_HOME="$IDE/jbr/Contents/Home"

cd "$PROJ"

BUNDLE=$(python3 -c "
import re
t=open('AppScope/app.json5').read()
m=re.search(r'\"bundleName\"\s*:\s*\"([^\"]+)\"',t)
print(m.group(1) if m else '')
")
ABILITY=$(python3 -c "
import re
t=open('entry/src/main/module.json5').read()
m=re.search(r'\"mainElement\"\s*:\s*\"([^\"]+)\"',t)
print(m.group(1) if m else 'EntryAbility')
")

echo "工程:    $PROJ"
echo "包名:    $BUNDLE"
echo "Ability: $ABILITY"
echo ""

echo "[1/4] 检查设备..."
if ! "$HDC" list targets 2>/dev/null | grep -qv "UART\|Empty"; then
  echo "  未检测到设备"
  exit 1
fi
echo "  设备: $("$HDC" list targets 2>/dev/null | grep -v UART | head -1)"

echo "[2/4] 构建..."
# 注意：必须保留 hvigor 的退出码。早先这里写成 `hvigor ... | grep ... | head`，
# 管道会把退出码吞掉，编译失败也照样往下走，最后把**上一次**的旧 .hap 装进手机，
# 并打印「安装成功」—— 表现为「改了代码但手机上毫无变化」。
BUILD_LOG=$(mktemp)
if ! "$NODE" "$HVIGOR" assembleHap -p product=default --no-daemon > "$BUILD_LOG" 2>&1; then
  echo "  ✗ 编译失败（下面是最关键的几行）："
  grep -E "Error Message|COMPILE RESULT|BUILD FAILED" "$BUILD_LOG" | head -12 | sed 's/^/    /'
  rm -f "$BUILD_LOG"
  exit 1
fi
grep -E "BUILD SUCCESSFUL" "$BUILD_LOG" | head -1 | sed 's/^/> /'
rm -f "$BUILD_LOG"

HAP=$(ls -t entry/build/*/outputs/*/entry-*signed.hap 2>/dev/null | head -1)
if [ -z "$HAP" ]; then
  HAP=$(ls -t entry/build/*/outputs/*/entry-*.hap 2>/dev/null | head -1)
fi
[ -f "$HAP" ] || { echo "  产物未找到"; exit 1; }

# 产物必须比源码新，否则说明这次构建其实没生成新包（缓存/失败都可能造成）
NEWEST_SRC=$(find entry/src/main/ets -name '*.ets' -newer "$HAP" -print -quit 2>/dev/null)
if [ -n "$NEWEST_SRC" ]; then
  echo "  ✗ 产物比源码旧（$NEWEST_SRC 更新），这次构建没有真正产出新包。"
  echo "    先删掉 entry/build 再重跑，或检查上面的编译输出。"
  exit 1
fi
echo "  产物: $(basename "$HAP") ($(du -h "$HAP" | cut -f1), $(date -r "$HAP" '+%H:%M:%S'))"

case "$HAP" in
  *unsigned*)
    echo ""
    echo "  ✗ 这是未签名包，装不进真机。"
    echo "    请在 DevEco Studio 里 File > Project Structure > Signing Configs"
    echo "    勾选 Automatically generate signature 后重新运行本脚本。"
    exit 1
    ;;
esac

echo "[3/4] 安装..."
OUT=$("$HDC" install -r "$HAP" 2>&1)
echo "$OUT" | grep -qi "success" || { echo "  安装失败: $OUT"; exit 1; }
echo "  安装成功"

echo "[4/4] 启动..."
OUT=$("$HDC" shell "aa start -a $ABILITY -b $BUNDLE" 2>&1)
if echo "$OUT" | grep -qi "success"; then
  echo "  ✓ 启动成功"
else
  echo "  $OUT"
  case "$OUT" in
    *"screen is locked"*) echo "  请先解锁手机屏幕" ;;
  esac
fi

echo ""
echo "完成。"