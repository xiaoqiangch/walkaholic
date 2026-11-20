#!/usr/bin/env bash
# 命令行构建 + 签名 HarmonyOS 工程，产物可直接装进模拟器/真机。
#
# 与 DevEco 图形界面等价，只是把签名那一步换成 hap-sign-tool 直签
# （hvigor 的 SignHap 要求加密格式的密码，命令行拼不出来）。
#
# 用法： bash scripts/build-hap.sh [--device]
#   --device  构建后安装并启动到已连接的设备/模拟器
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$ROOT/harmony"
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
  [ -x "$f" ] || { echo "缺少 $f（先跑 scripts/setup-deveco-cli.sh）"; exit 1; }
done
[ -f "$SIGN_DIR/profile.p7b" ] || { echo "缺少签名材料（先跑 scripts/gen-local-sign.sh）"; exit 1; }

cd "$PROJ"

echo "═══ 1. 编译（hvigor assembleHap）═══"
# SignHap 会在签名配置上报错，允许它失败，只要 unsigned 包产出就算成功
set +e
"$NODE" "$HVIGOR" assembleHap -p product=default --no-daemon 2>&1 | \
  grep -E "ERROR|BUILD|CompileArkTS|PackageHap" | head -20
set -e

UNSIGNED=$(ls -t entry/build/*/outputs/*/entry-*unsigned.hap 2>/dev/null | head -1 || true)
[ -n "$UNSIGNED" ] || { echo "未找到 unsigned 产物，编译失败"; exit 1; }
echo "  unsigned: $(basename "$UNSIGNED") ($(du -h "$UNSIGNED" | cut -f1))"

echo "═══ 2. 本地签名（hap-sign-tool）═══"
SIGNED="$PROJ/entry/build/default/outputs/default/entry-default-signed.hap"
mkdir -p "$(dirname "$SIGNED")"
"$JAVA" -jar "$SIGN" sign-app \
  -keyAlias "openharmony application release" -signAlg "SHA256withECDSA" -mode "localSign" \
  -appCertFile "$SIGN_DIR/app-cert-chain.cer" -profileFile "$SIGN_DIR/profile.p7b" \
  -inFile "$UNSIGNED" -keystoreFile "$SIGN_DIR/OpenHarmony.p12" -outFile "$SIGNED" \
  -keyPwd "123456" -keystorePwd "123456" 2>&1 | grep -E "success|ERROR" | sed 's/^/  /'

echo "═══ 3. 校验签名 ═══"
"$JAVA" -jar "$SIGN" verify-app -inFile "$SIGNED" \
  -outCertChain /tmp/verify-chain.cer -outProfile /tmp/verify-profile.p7b 2>&1 | \
  grep -E "Verify success|verify-app success|ERROR" | sed 's/^/  /'

echo
echo "✅ 产物: $SIGNED ($(du -h "$SIGNED" | cut -f1))"

if [ "${1:-}" = "--device" ]; then
  echo "═══ 4. 安装到设备 ═══"
  TARGETS=$("$HDC" list targets 2>/dev/null | grep -v -E "Empty|UART" | head -1)
  [ -n "$TARGETS" ] || { echo "  未检测到设备，请先启动模拟器"; exit 1; }
  echo "  设备: $TARGETS"
  "$HDC" install -r "$SIGNED" 2>&1 | tail -2
  BUNDLE=$(python3 -c "
import re,sys
t=open('AppScope/app.json5').read()
m=re.search(r'\"bundleName\"\s*:\s*\"([^\"]+)\"',t)
print(m.group(1) if m else 'com.walkaholic.harmony')")
  "$HDC" shell "aa start -a EntryAbility -b $BUNDLE" 2>&1 | head -2
fi
