#!/usr/bin/env bash
# 命令行构建 + 签名 HarmonyOS 工程，产物可直接装进模拟器/真机。
#
# 签名走两条路，自动选择：
#   1) hvigor 自带 SignHap —— build-profile.json5 里配了 DevEco 图形界面生成的
#      HarmonyOS 签名（~/.ohos/config/*），真机可装，首选。
#   2) hap-sign-tool + OpenHarmony SDK CA 本地自签（scripts/gen-local-sign.sh 产出），
#      没有华为账号时用，产物只能本机/模拟器调试。
#
# 用法： bash scripts/build-hap.sh [--device]
#   --device  构建后安装并启动到已连接的设备/模拟器
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$ROOT/harmony"

# 工具链定位：优先 ~/DevTools/deveco（setup-deveco-cli.sh 复制的副本，绕开
# macOS 26 App Management 拦截），否则回落 .app 包内（外置卷上的 .app 不被拦）。
if [ -z "${DEVECO_CLI_HOME:-}" ]; then
  for cand in "$HOME/DevTools/deveco" \
              "/Volumes/XQProjects/DevTools/apps/DevEco-Studio.app/Contents" \
              "/Applications/DevEco-Studio.app/Contents"; do
    [ -x "$cand/tools/node/bin/node" ] && { DEVECO_CLI_HOME="$cand"; break; }
  done
fi
HOME_DEVECO="${DEVECO_CLI_HOME:-$HOME/DevTools/deveco}"
LIB="$HOME_DEVECO/sdk/default/openharmony/toolchains/lib"
JAVA="$HOME_DEVECO/jbr/Contents/Home/bin/java"
NODE="$HOME_DEVECO/tools/node/bin/node"
HVIGOR="$HOME_DEVECO/tools/hvigor/bin/hvigorw.js"
HDC="$HOME_DEVECO/sdk/default/openharmony/toolchains/hdc"
SIGN="$LIB/hap-sign-tool.jar"
SIGN_DIR="${LOCAL_SIGN_DIR:-$HOME/.deveco/localsign}"

export DEVECO_SDK_HOME="$HOME_DEVECO/sdk"
export JAVA_HOME="$HOME_DEVECO/jbr/Contents/Home"

for f in "$NODE" "$HVIGOR" "$JAVA" "$HDC"; do
  [ -x "$f" ] || { echo "缺少 ${f}（先跑 scripts/setup-deveco-cli.sh）"; exit 1; }
done

cd "$PROJ"

BUNDLE=$(python3 -c "
import re
t=open('AppScope/app.json5').read()
m=re.search(r'\"bundleName\"\s*:\s*\"([^\"]+)\"',t)
print(m.group(1) if m else 'com.walkaholic.harmony')")

echo "═══ 1. 编译（hvigor assembleHap）═══"
# 不能把 hvigor 输出直接管道给 grep —— 管道退出码是 grep 的，编译失败会被吞掉，
# 最后签名/安装的还是**上一次**的旧 .hap（表现为「改了代码但手机上毫无变化」）。
BUILD_LOG=$(mktemp)
set +e
"$NODE" "$HVIGOR" assembleHap -p product=default --no-daemon >"$BUILD_LOG" 2>&1
BUILD_RC=$?
set -e
grep -E "BUILD SUCCESSFUL|BUILD FAILED|COMPILE RESULT" "$BUILD_LOG" | head -5 || true
if [ "$BUILD_RC" -ne 0 ] && ! grep -q "BUILD SUCCESSFUL" "$BUILD_LOG"; then
  echo "  ✗ 编译失败。关键行："
  grep -E "Error Message|ERROR|COMPILE RESULT|BUILD FAILED" "$BUILD_LOG" | head -15 | sed 's/^/    /'
  rm -f "$BUILD_LOG"
  exit 1
fi
rm -f "$BUILD_LOG"

UNSIGNED=$(ls -t entry/build/*/outputs/*/entry-*unsigned.hap 2>/dev/null | head -1 || true)
[ -n "$UNSIGNED" ] || { echo "  ✗ 未找到 unsigned 产物，编译失败"; exit 1; }
echo "  unsigned: $(basename "$UNSIGNED") ($(du -h "$UNSIGNED" | cut -f1))"

echo "═══ 2. 签名 ═══"
HVIGOR_SIGNED=$(ls -t entry/build/*/outputs/*/entry-*signed.hap 2>/dev/null | head -1 || true)
SIGNED=""
if [ -n "$HVIGOR_SIGNED" ] && "$JAVA" -jar "$SIGN" verify-app -inFile "$HVIGOR_SIGNED" \
     -outCertChain /tmp/wa-chain.cer -outProfile /tmp/wa-profile.p7b >/dev/null 2>&1; then
  SIGNED="$HVIGOR_SIGNED"
  echo "  用 hvigor 自带的 HarmonyOS 签名（~/.ohos/config），验签通过"
elif [ -f "$SIGN_DIR/profile.p7b" ]; then
  echo "  hvigor 签名不可用，改用本地自签（OpenHarmony SDK CA）"
  SIGNED="$PROJ/entry/build/default/outputs/default/entry-default-signed.hap"
  mkdir -p "$(dirname "$SIGNED")"
  "$JAVA" -jar "$SIGN" sign-app \
    -keyAlias "openharmony application release" -signAlg "SHA256withECDSA" -mode "localSign" \
    -appCertFile "$SIGN_DIR/app-cert-chain.cer" -profileFile "$SIGN_DIR/profile.p7b" \
    -inFile "$UNSIGNED" -keystoreFile "$SIGN_DIR/OpenHarmony.p12" -outFile "$SIGNED" \
    -keyPwd "123456" -keystorePwd "123456" 2>&1 | grep -E "success|ERROR" | sed 's/^/  /' || true
  "$JAVA" -jar "$SIGN" verify-app -inFile "$SIGNED" \
    -outCertChain /tmp/wa-chain.cer -outProfile /tmp/wa-profile.p7b 2>&1 | \
    grep -E "Verify success|ERROR" | sed 's/^/  /' || true
else
  echo "  ✗ 没有可用的签名材料："
  echo "    · 想用华为账号签名 → DevEco Studio: File > Project Structure > Signing Configs"
  echo "    · 想用本地自签     → bash scripts/gen-local-sign.sh"
  exit 1
fi

echo
echo "✅ 产物: $SIGNED ($(du -h "$SIGNED" | cut -f1))"

if [ "${1:-}" = "--device" ]; then
  echo "═══ 3. 安装到设备 ═══"
  TARGETS=$("$HDC" list targets 2>/dev/null | grep -v -E "Empty|UART" | head -1 || true)
  if [ -z "$TARGETS" ]; then
    cat <<'MSG'
  ✗ 未检测到设备。手机端逐项确认：
    1. 设置 → 关于本机 → 连点版本号 7 次，进入开发者模式
    2. 设置 → 系统和更新 → 开发人员选项 → 打开「USB 调试」
    3. 插线后手机弹「是否允许 USB 调试」→ 允许（勾选「始终允许」）
    4. 下拉通知栏，USB 连接方式选「传输文件」或「仅充电」都行，但要能出 HDC 接口
  然后重跑：bash scripts/build-hap.sh --device
MSG
    exit 1
  fi
  echo "  设备: $TARGETS"
  "$HDC" install -r "$SIGNED" 2>&1 | tail -2
  echo "  启动…"
  OUT=$("$HDC" shell "aa start -a EntryAbility -b $BUNDLE" 2>&1 | head -2 || true)
  echo "  $OUT"
  case "$OUT" in
    *"screen is locked"*) echo "  ⚠ 手机锁屏中，解锁后再点图标启动" ;;
  esac
fi
